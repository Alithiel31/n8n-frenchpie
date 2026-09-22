*[English version](architecture.md)*

# Architecture

Ce document va plus loin que l'aperçu du README : comment les pièces s'assemblent, et pourquoi chaque choix a été fait.

## Flux réseau

```
Navigateur / app mobile (client Tailscale, n'importe où sur le tailnet)
        │
        │  HTTP, port 5678
        ▼
Raspberry Pi 3B+ "FrenchPie" (IP Tailscale <IP_TAILSCALE_HOTE_N8N>)
        │
        │  Docker : port host 5678 → port conteneur 5678 (réseau bridge, mapping de port standard)
        ▼
   Conteneur n8n
        │
        │  TCP sortant, port 5432, via le tailnet (NAT sortant par défaut de Docker — aucune config spéciale)
        ▼
Hôte "Caesura" (IP Tailscale <IP_TAILSCALE_CAESURA>)
        │
        ▼
   Processus PostgreSQL 17 natif (pas containerisé), base "n8n", utilisateur "n8n_app"
```

Deux hôtes reliés par Tailscale, deux rôles différents : FrenchPie fait tourner l'application, Caesura fait tourner la base mutualisée utilisée par plusieurs projets de ce homelab (n8n est un locataire parmi d'autres sur cette même instance Postgres).

## Pourquoi pas de Traefik

Tous les autres services de ce homelab passent par Traefik pour le HTTPS automatique et le routage. n8n sur FrenchPie non, pour deux raisons :

- FrenchPie ne fait pas tourner sa propre instance Traefik, et en ajouter une juste pour un seul service Tailscale-only ne vaut pas le coût sur un Pi 3B+ avec 1 Go de RAM.
- L'accès est Tailscale-only. Chaque client qui joint n8n est déjà authentifié par la couche réseau de Tailscale elle-même (basée WireGuard, liée à l'identité). Il n'y a pas de surface publique à protéger avec de la terminaison TLS, donc du HTTP simple sur le tailnet est un compromis acceptable ici — ça ne le serait pas si ce service devait un jour être exposé publiquement (voir le point "si besoin d'exposition publique" dans le README).

## Pourquoi Postgres reste distant (sur Caesura, pas sur FrenchPie)

Deux raisons pratiques :

- **Matériel.** Un Pi 3B+ avec 1 Go de RAM et une carte SD est un mauvais hôte pour une base de données — les cartes SD se dégradent sous charge d'écriture soutenue, et la RAM est déjà serrée rien que pour n8n lui-même (voir les chiffres RAM de la section "vérifications avant déploiement" du README).
- **Consolidation.** Caesura fait déjà tourner une instance Postgres 17 mutualisée utilisée par d'autres projets du homelab. Ajouter une base de plus (`n8n`, possédée par un utilisateur dédié `n8n_app`, isolée des autres bases sur la même instance) coûte moins cher à opérer et à sauvegarder que de monter une seconde instance Postgres sur une machine qui peine déjà à faire tourner autre chose.

C'est aussi pour ça que ce déploiement n'a pas besoin du bricolage `extra_hosts: host.docker.internal:host-gateway` : ce contournement existe pour le cas où un conteneur doit joindre un service sur son *propre* hôte via la gateway IP du bridge Docker. Ici, Postgres est sur une machine totalement différente, jointe via le tailnet comme n'importe quel autre hôte distant — le NAT sortant par défaut de Docker s'en charge sans aucune config spéciale.

## Spécificités réseau Docker

- Aucun réseau Docker custom n'est défini ; n8n utilise le réseau bridge par défaut créé pour le conteneur.
- Le mapping `ports: - "5678:5678"` dans `docker-compose.yml` publie le port du conteneur directement sur le réseau hôte de FrenchPie, lui-même sur le tailnet. C'est ce qui rend `http://<IP_TAILSCALE_HOTE_N8N>:5678` joignable depuis n'importe où sur le tailnet.
- Le trafic sortant vers Postgres (`DB_POSTGRESDB_HOST=<IP_TAILSCALE_CAESURA>`) sort du conteneur via le NAT sortant standard de Docker, atteint l'interface `tailscale0` de FrenchPie, et est routé via le tailnet jusqu'à Caesura — comme si n'importe quel autre processus sur FrenchPie ouvrait directement cette connexion.

## cgroups et `mem_limit`

Raspberry Pi OS (comme plusieurs autres dérivés Debian minimaux/embarqués) est livré avec le contrôleur cgroup mémoire du noyau **désactivé par défaut**, pour économiser un peu de surcharge au boot et à l'exécution. La directive `mem_limit` de Docker dans `docker-compose.yml` (fixée à `450m` ici, volontairement conservatrice sur une machine à 1 Go qui fait aussi tourner l'OS et Docker lui-même) dépend entièrement de ce contrôleur : sans lui, Docker accepte silencieusement la directive mais ne l'applique jamais (visible via `WARNING: No memory limit support` dans `docker info`).

L'activer nécessite un changement de paramètre de boot du noyau (`cgroup_enable=memory cgroup_memory=1` dans `/boot/firmware/cmdline.txt`) et un reboot — un changement ponctuel, au niveau de l'hôte, indépendant du déploiement n8n lui-même. Voir l'étape 2 du README et le point 1 de `docs/troubleshooting.fr.md` pour les commandes concrètes.

## Flux des secrets au moment du déploiement

Aucun secret n'est jamais écrit en clair sur disque dans les fichiers propres à ce déploiement (`.env` et `.infisical-identity.env` ne contiennent que des identifiants, les credentials pour Infisical lui-même, et des paramètres de connexion — pas les secrets applicatifs `N8N_ENCRYPTION_KEY` / `N8N_DB_PASS`, qui vivent uniquement dans Infisical).

`deploy.sh` fait ceci à chaque déploiement :

1. Source `.infisical-identity.env` (Client ID/Secret de la Machine Identity) et `.env` (domaine Infisical, ID de projet, plus les valeurs non-secrètes `N8N_HOST`/`DB_HOST`).
2. S'authentifie auprès d'Infisical via `infisical login --method=universal-auth`, obtenant un token d'accès Infisical de courte durée — cette étape ne touche jamais aux secrets applicatifs eux-mêmes, elle prouve seulement l'identité de la machine qui déploie auprès d'Infisical.
3. Lance `infisical run ... -- docker compose up -d` : le CLI Infisical récupère à ce moment les secrets de l'environnement `prod` (`N8N_ENCRYPTION_KEY`, `N8N_DB_PASS`), les injecte comme variables d'environnement uniquement dans le processus `docker compose up`, et ils passent de là dans l'environnement du conteneur via les références `${...}` de `docker-compose.yml`.

Les secrets n'existent en clair que de façon transitoire, en mémoire du processus `docker compose up` et de l'environnement du conteneur résultant — jamais écrits dans un fichier sur le disque de FrenchPie par l'outillage propre à ce déploiement, et jamais commités dans le contrôle de version.
