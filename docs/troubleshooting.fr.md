*[English version](troubleshooting.md)*

# Dépannage

Notes détaillées sur chaque souci rencontré pendant ce déploiement — symptôme, cause, correctif. Gardé ici plutôt que dans le README principal pour que celui-ci reste un guide de démarrage rapide.

## 1. `docker info` affiche `WARNING: No memory limit support` / `No swap limit support`

**Symptôme** : le `mem_limit` du compose ne semble limiter en rien le conteneur — il peut dépasser la limite configurée.

**Cause** : les cgroups mémoire sont désactivés par défaut sur certaines images Raspberry Pi OS / Debian, pour économiser un peu de RAM au boot.

**Correctif** :
```bash
sudo nano /boot/firmware/cmdline.txt
```
Ajouter à la fin de la (seule) ligne :
```
cgroup_enable=memory cgroup_memory=1
```
Redémarrer, puis vérifier :
```bash
cat /proc/cmdline                    # doit contenir les deux flags
cat /sys/fs/cgroup/cgroup.controllers # doit lister "memory"
docker info | grep -i "memory\|swap" # les WARNING doivent avoir disparu
```
Remarque : un `cgroup_disable=memory` qui traîne plus tôt sur la même ligne (présent par défaut sur certaines images Pi) ne bloque pas forcément le résultat — se fier à `cgroup.controllers` comme source de vérité plutôt que de supposer que le flag de désactivation l'emporte.

## 2. La connexion échoue silencieusement en HTTP simple

**Symptôme** : le formulaire de login de n8n se soumet mais rien ne se passe, aucune erreur, aucune session créée.

**Cause** : n8n utilise par défaut des cookies de session `Secure`, que les navigateurs refusent de stocker en HTTP simple.

**Correctif** : définir `N8N_SECURE_COOKIE=false` — nécessaire tant qu'il n'y a pas de TLS devant n8n (accès Tailscale-only en HTTP, comme ici).

## 3. `extra_hosts: host.docker.internal:host-gateway` résout vers la mauvaise IP

**Symptôme** : un conteneur sur un réseau Docker custom ne peut pas joindre un service tournant sur le Postgres de l'hôte (ou tout autre service lié à l'hôte) — les connexions timeout silencieusement.

**Cause** : la valeur magique `host-gateway` résout toujours vers la gateway du réseau bridge *par défaut* (généralement `172.17.0.1`), jamais vers celle d'un réseau custom.

**Correctif** : hardcoder la vraie gateway du réseau custom :
```yaml
extra_hosts:
  - "host.docker.internal:172.x.x.1"   # la vraie gateway de ton réseau custom
```
Non applicable à ce déploiement précis (Postgres est distant, joint via Tailscale, pas via `host.docker.internal`) — documenté ici car c'est un piège récurrent sur d'autres services du même homelab (Gitea/Woodpecker, tous deux avec Postgres local).

## 4. La perte de `N8N_ENCRYPTION_KEY` rend toutes les credentials illisibles

**Symptôme** : après rotation ou perte de la clé de chiffrement, toutes les credentials stockées dans les workflows existants échouent au déchiffrement.

**Cause** : cette clé est ce que n8n utilise pour chiffrer les credentials au repos dans Postgres — elle n'est dérivée de rien d'autre et n'a aucune sauvegarde côté serveur par défaut.

**Correctif** : il n'y en a pas après coup. La générer une seule fois (`openssl rand -hex 32`), la stocker dans Infisical (ou un autre gestionnaire de secrets) comme source de vérité unique, et ne jamais la régénérer sans un plan de migration des credentials délibéré.

## 5. Machine Identity Infisical : deux ID différents

**Symptôme** : `infisical login --method=universal-auth` échoue avec `401 Invalid credentials`, même en ayant copié le Client ID et le Secret avec soin.

**Cause** : la page de détails d'une Machine Identity affiche un champ **"ID"** en haut (l'identifiant interne de l'identité, utilisé pour les références de rôle/accès) — c'est une valeur différente du **"Client ID"** utilisé pour le login Universal Auth, qui n'apparaît que dans le panneau de configuration "Universal Auth" (cliquer sur la ligne "Universal Auth" dans Authentication).

**Correctif** : toujours copier le Client ID depuis ce panneau, pas depuis la carte "Details" de l'identité. Le Client Secret affiché dans le même panneau, lui, est correct dans tous les cas.

## 6. `DOCKER_HOST` écrase silencieusement `DOCKER_CONTEXT`

**Symptôme** : `export DOCKER_CONTEXT=<nom>` puis `docker context show` affiche toujours `default`, et `docker info` cible toujours le mauvais hôte.

**Cause** : si la variable d'environnement `DOCKER_HOST` est définie quelque part dans l'environnement du shell (souvent exportée dans `.bashrc`/`.bash_profile` pour un hôte distant "par défaut"), elle prend le pas sur la sélection de contexte, entièrement. Docker affiche d'ailleurs un warning explicite à ce sujet sur `docker context ls`.

**Correctif** : pour une session ponctuelle ciblant un autre hôte, écraser `DOCKER_HOST` directement plutôt que de lutter via le contexte :
```bash
export DOCKER_HOST="ssh://<utilisateur>@<ip-tailscale-hote-cible>"
```
Ça reste scopé au shell courant — les autres terminaux et le profil persistant ne sont pas affectés.

## 7. `503 Database is not ready!` à la première création du compte owner

**Symptôme** : soumettre le formulaire "Set up owner account" renvoie une `503` avec `{"code":503,"message":"Database is not ready!"}`.

**Cause** : un hoquet de connectivité Postgres transitoire (voir #8) pile au moment de la requête. La création du compte peut quand même se terminer côté serveur, même si la réponse HTTP qui arrive au navigateur est une erreur.

**Correctif** : avant de resoumettre le formulaire, vérifier les logs du conteneur :
```bash
docker logs n8n --tail 50
```
Si `Owner was set up successfully` apparaît malgré l'erreur côté navigateur, le compte existe — se connecter directement sur `/signin` avec les identifiants saisis, plutôt que de resoumettre le setup (qui échouerait alors différemment, un owner existant déjà).

## 8. `Database ping failed: Database connection timed out` récurrent

**Symptôme** : `docker logs n8n` affiche ce message de façon répétée, alternant avec `Database connection recovered` — l'appli continue de fonctionner, mais le motif se répète.

**Cause probable** : quand la liaison Tailscale entre l'hôte n8n et l'hôte Postgres passe par un relais DERP plutôt qu'une connexion directe pair-à-pair, la latence devient plus élevée et plus variable, ce qui peut faire sauter les timeouts du client Postgres sous charge — en particulier juste après une opération lourde en ressources (ex. un pull d'image lent sur du matériel contraint) qui laisse l'hôte et sa pile réseau sous pression.

**Diagnostic** :
```bash
tailscale ping <nom-hote-postgres>
```
Chercher `via DERP(...)` dans la sortie (relayé) versus une IP directe (`via <ip>:<port>` sans préfixe DERP — après le premier ou les deux premiers paquets de sonde, qui passent souvent par DERP pendant que le chemin direct est encore en train de s'établir).

**Correctif / mitigation** : si systématiquement relayé, creuser pourquoi une connexion directe ne se forme pas (généralement des restrictions NAT/UPnP sur le routeur d'un des deux côtés — voir la [doc Tailscale sur le NAT traversal](https://tailscale.com/kb/1257/connection-types)). Si ça se résout tout seul en direct après les premiers paquets et que les timeouts cessent de se répéter en usage normal (hors démarrage), c'est probablement juste de la pression ressources au démarrage, pas un souci durable.

## 9. Pull d'image et migrations lents sur matériel contraint

**Symptôme** : `deploy.sh` semble bloqué longtemps sur `Pulling` pendant `docker compose up`, ou le premier chargement de la page affiche "n8n is starting up" pendant plusieurs minutes.

**Cause** : un Raspberry Pi 3B+ avec carte SD est simplement lent à décompresser une image de ~260 Mo, et n8n exécute des centaines de migrations DB séquentielles au premier démarrage (chacune un aller-retour réseau vers Postgres).

**Correctif** : aucun nécessaire — juste de la patience. Utiliser un second terminal pour suivre la progression sans interrompre le premier :
```bash
docker ps -a
docker logs n8n --tail 30
```
Un temps de pull de l'ordre de 15-20 minutes sur ce type de matériel est normal, pas un blocage.
