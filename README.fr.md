*[English version](README.md)*

# n8n — FrenchPie

Automatisation de workflows (n8n), hébergé sur un Raspberry Pi 3B+ (ici nommé **FrenchPie**), avec la base de données sur le **Postgres 17 mutualisé** d'un autre hôte du homelab (ici **Caesura**) via Tailscale. Accès Tailscale uniquement, pas d'exposition publique.

Les IP, noms de machines et domaine Tailscale ci-dessous sont anonymisés en placeholders (`<...>`) dans ce README et dans `.env.example` — les vraies valeurs vivent uniquement dans `.env` et `.infisical-identity.env`, tous deux ignorés par git.

## Architecture

```
Navigateur / app mobile (client Tailscale)
        │  http://<IP_TAILSCALE_FRENCHPIE>:5678
        ▼
   Conteneur n8n (FrenchPie, port host 5678)
        │  connexion sortante via tailnet
        ▼
   Postgres 17 natif de Caesura (<IP_TAILSCALE_CAESURA>:5432, base "n8n")
```

Contrairement à un déploiement où Postgres tourne sur la *même* machine que les conteneurs (auquel cas il faut bricoler `extra_hosts`/gateway custom), ici Postgres est sur une machine distante — le conteneur n8n joint directement l'IP Tailscale de Caesura via le NAT sortant standard de Docker, FrenchPie étant lui-même sur le tailnet.

Pas de Traefik ici : FrenchPie n'en fait pas tourner, et l'accès reste Tailscale-only donc pas besoin de reverse proxy.

## Prérequis

- Un hôte (ici FrenchPie) avec Docker installé, sur le même tailnet que l'hôte Postgres
- Un Postgres mutualisé joignable via Tailscale (ou tout autre Postgres accessible depuis FrenchPie)
- Une instance [Infisical](https://infisical.com/) self-hébergée (ou cloud) pour la gestion des secrets, avec un projet contenant un environnement `prod`
- Le CLI `infisical` installé sur la machine qui lance `deploy.sh` (peut être FrenchPie lui-même, ou une autre machine pilotant Docker à distance via `DOCKER_HOST`/`docker context`)

## Vérifications faites avant déploiement (référence, sur le Pi 3B+ utilisé ici)

- Architecture : `aarch64` (64 bits) → l'image officielle `n8nio/n8n` est compatible (une image 32 bits `armv7l` ne l'est pas)
- RAM : **serrée sur un Pi 3B+** — 905 Mi au total, ~700 Mi disponibles, 210 Mi libres au repos. Swap non utilisé au départ (filet de sécurité, mais lent sur carte SD)
- Disque : quelques Go dispo sur `/`, suffisant pour l'image + les données n8n
- Port 5678 : à vérifier libre (`sudo ss -tulpn | grep 5678`)
- Connectivité Tailscale vers l'hôte Postgres : `tailscale ping <nom-hote-postgres>` doit répondre (voir plus bas si la réponse passe par un relais DERP)

## Étapes de déploiement

### 1. Installer Docker sur l'hôte cible

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker <utilisateur>
# se déconnecter/reconnecter en SSH pour que l'appartenance au groupe docker prenne effet
```

### 2. Activer les cgroups mémoire (Raspberry Pi OS / Debian, souvent désactivés par défaut)

Sans ça, `mem_limit` dans le compose est **silencieusement ignoré** (Docker affiche `WARNING: No memory limit support` / `No swap limit support` dans `docker info`) :

```bash
sudo nano /boot/firmware/cmdline.txt
```
Ajouter à la fin de la ligne (espace séparateur, tout sur une seule ligne) :
```
cgroup_enable=memory cgroup_memory=1
```
Puis :
```bash
sudo reboot
```
Après reboot, vérifier :
```bash
cat /proc/cmdline                    # doit contenir les deux flags
cat /sys/fs/cgroup/cgroup.controllers # doit lister "memory"
docker info | grep -i "memory\|swap" # les WARNING doivent avoir disparu
```

### 3. Côté hôte Postgres — créer la base

```bash
openssl rand -hex 32   # génère le mot de passe applicatif, à garder de côté
sudo -u postgres psql -c "CREATE USER n8n_app WITH PASSWORD '<mot_de_passe_genere>';"
sudo -u postgres psql -c "CREATE DATABASE n8n OWNER n8n_app;"
```

### 4. Côté hôte Postgres — autoriser l'hôte n8n à se connecter

Vérifier `pg_hba.conf` : si une règle couvre déjà toute la plage CGNAT Tailscale (`100.64.0.0/10`, la plage utilisée par toutes les IP d'un tailnet), rien à ajouter. Sinon, ajouter une ligne pour l'IP Tailscale précise de l'hôte n8n :
```
host    n8n    n8n_app    <IP_TAILSCALE_HOTE_N8N>/32    scram-sha-256
```
```bash
sudo systemctl reload postgresql
sudo ufw allow from <IP_TAILSCALE_HOTE_N8N> to any port 5432 proto tcp
```

### 5. Créer la Machine Identity Infisical

Dans Infisical → ton projet de secrets → Access Control → Machine Identities → **Create Identity**
- Nom : `n8n-deploy`
- Méthode d'auth : Universal Auth
- Rôle : accès en lecture (`Viewer`) sur l'environnement `prod`

⚠️ **Piège** : une fois l'identité créée, la page "Details" affiche un champ **"ID"** — ce n'est **PAS** le Client ID à utiliser. Il faut cliquer sur la ligne "Universal Auth" dans la section Authentication pour ouvrir son panneau de configuration, qui affiche le **vrai "Client ID"** (différent de l'ID de l'identité) ainsi que la liste des **Client Secrets**. Utiliser l'ID affiché *dans ce panneau*, sinon l'authentification échoue avec une erreur 401 `Invalid credentials` qui ne donne aucun indice sur la cause réelle.

Génère un Client Secret depuis ce même panneau (**"Add Client Secret"**) — il n'est affiché qu'une seule fois, à copier immédiatement.

### 6. Ajouter les 2 secrets applicatifs dans Infisical (environnement `prod`)

- `N8N_ENCRYPTION_KEY` → générer avec `openssl rand -hex 32` — **ne jamais la perdre ni la changer après coup**, sinon toutes les credentials stockées dans les workflows deviennent illisibles
- `N8N_DB_PASS` → le mot de passe créé à l'étape 3

### 7. Installer le CLI Infisical (sur la machine qui va lancer `deploy.sh`)

```bash
curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | sudo -E bash
sudo apt install infisical
```

### 8. Configurer le dossier de déploiement

```bash
cp .env.example .env
# éditer .env : IP Tailscale des deux hôtes, domaine Infisical, ID du projet Infisical

cp .infisical-identity.env.example .infisical-identity.env
# éditer .infisical-identity.env avec le Client ID (celui du panneau Universal Auth,
# pas l'ID de l'identité) et le Client Secret de l'étape 5
```

### 9. Déployer

**Option A — directement sur l'hôte cible** (SSH dessus, `cd` dans ce dossier, puis) :
```bash
./deploy.sh
```

**Option B — à distance, depuis une autre machine, via un contexte Docker SSH** (évite de transférer le dossier — on déploie depuis là où il se trouve, en ciblant l'hôte distant) :
```bash
export DOCKER_HOST="ssh://<utilisateur>@<IP_TAILSCALE_HOTE_CIBLE>"
./deploy.sh
```
⚠️ **Piège** : si `DOCKER_HOST` est déjà exporté ailleurs (`.bashrc`, profil shell) vers une *autre* machine, il prend le pas sur `docker context use` / `DOCKER_CONTEXT` — Docker l'indique lui-même dans un warning (`DOCKER_HOST environment variable overrides the active context`). Écraser `DOCKER_HOST` directement pour la session courante (comme ci-dessus) est plus fiable que de créer un contexte nommé dans ce cas.

Le pull de l'image (~260 Mo) peut prendre **plusieurs dizaines de minutes** sur un Pi 3B+ avec une carte SD lente — ce n'est pas un blocage, juste de la lenteur matérielle. Vérifier la progression avec `docker ps -a` / `docker logs n8n --tail 30` dans un second terminal plutôt que d'interrompre.

### 10. Premier accès

`http://<IP_TAILSCALE_HOTE_N8N>:5678` — depuis n'importe quel appareil connecté au tailnet.

⚠️ **Piège** : au premier démarrage, n8n fait défiler des **centaines de migrations DB** (une par une, chacune étant un aller-retour réseau vers Postgres) — ça peut prendre plusieurs minutes en plus du démarrage du conteneur lui-même. Si la page affiche "n8n is starting up. Please wait", c'est normal, attendre.

Si la soumission du formulaire de création de compte owner renvoie une erreur `503 Database is not ready!` : ce n'est pas forcément un échec. Vérifier les logs (`docker logs n8n --tail 30`) — si la ligne `Owner was set up successfully` apparaît malgré l'erreur affichée côté navigateur, le compte a bien été créé (la requête a réussi côté serveur juste après un timeout DB transitoire). Se connecter directement sur `/signin` avec les identifiants saisis plutôt que de recommencer le setup.

## Multi-utilisateurs

n8n Community Edition (sans licence, ce qui est le cas ici) permet plusieurs comptes utilisateurs : **Settings → Users → Invite**. Sans SMTP configuré (pas le cas ici), n8n génère un **lien d'invitation** à copier et transmettre manuellement plutôt que d'envoyer un email — la personne invitée définit son propre mot de passe en cliquant dessus. Le partage fin de workflows/credentials entre comptes est en revanche limité en Community Edition (fonctionnalités avancées réservées à l'Enterprise).

## À faire après déploiement

- [ ] Surveiller `docker stats n8n` dans les 24-48h — la RAM est le point le plus susceptible de poser souci sur du matériel contraint (type Pi 3B+)
- [ ] Vérifier que la base "n8n" est bien couverte par la stratégie de backup Postgres existante côté hôte DB
- [ ] Si l'hôte n8n n'a pas de mécanisme de backup propre, ajouter le volume `n8n-data` (contient la clé de chiffrement et les données locales) à une stratégie de sauvegarde
- [ ] Si les messages `Database ping failed: Database connection timed out` (visibles dans `docker logs`) persistent en usage normal (pas juste au démarrage), vérifier si la connexion Tailscale entre les deux hôtes passe par un relais DERP plutôt qu'en direct (`tailscale ping <hote>`) — un lien relayé ajoute de la latence variable qui peut faire timeout des requêtes DB sous charge
- [ ] Si besoin d'exposition publique un jour (webhooks entrants de services tiers) : revoir toute l'archi (Traefik, tunnel, `N8N_SECURE_COOKIE`, `WEBHOOK_URL`)

## Points d'attention / pièges rencontrés

1. **cgroups mémoire désactivés par défaut** sur certaines images Raspberry Pi OS/Debian — `mem_limit` du compose est ignoré sans `cgroup_enable=memory cgroup_memory=1` dans `cmdline.txt` (+ reboot). Voir étape 2.
2. **`N8N_SECURE_COOKIE=false` nécessaire** tant qu'il n'y a pas de TLS devant n8n (HTTP simple, Tailscale-only) — sinon le cookie de session est refusé et le login casse silencieusement.
3. **`extra_hosts: host.docker.internal:host-gateway` ne marche pas** sur un réseau Docker custom si jamais Postgres tourne en local sur le même hôte que n8n (cas différent de ce déploiement, où Postgres est distant) — toujours hardcoder la vraie gateway du réseau custom dans ce cas.
4. **`N8N_ENCRYPTION_KEY` ne doit jamais être régénérée après coup** sans plan de migration — c'est la clé qui déchiffre toutes les credentials des workflows existants.
5. **Deux ID différents sur une Machine Identity Infisical** : l'"ID" affiché sur la page de détails de l'identité n'est pas le "Client ID" de sa méthode Universal Auth (visible seulement en ouvrant le panneau "Universal Auth"). Les confondre donne un 401 `Invalid credentials` sans indice utile. Voir étape 5.
6. **`DOCKER_HOST` prend le pas sur `DOCKER_CONTEXT`** — si la variable d'environnement `DOCKER_HOST` est déjà définie (profil shell), `export DOCKER_CONTEXT=<nom>` seul ne change rien tant que `DOCKER_HOST` reste défini. Docker l'indique dans un warning explicite.
7. **Secrets gérés via Infisical**, jamais de mot de passe en clair dans `.env` ou committé — voir `deploy.sh`.
8. **Image et migrations lentes sur matériel contraint** (Pi 3B+, carte SD) — plusieurs dizaines de minutes pour le pull, plusieurs minutes pour les migrations DB au premier démarrage. Patience plutôt qu'interruption.

## Statut

✅ Déployé et fonctionnel — conteneur `n8n` up, connexion à Postgres distant opérationnelle, compte owner créé.
⬜ À surveiller : stabilité de la connexion Tailscale vers l'hôte Postgres sous usage prolongé (voir section "À faire après déploiement").
