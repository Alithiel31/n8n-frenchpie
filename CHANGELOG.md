# Changelog

All notable changes to this project are documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.0.0] - 2026-09-22

### Added

- Initial deployment of n8n on FrenchPie (Raspberry Pi 3B+), with the database hosted on the shared PostgreSQL 17 instance on Caesura, reached over Tailscale.
- `docker-compose.yml` defining the single `n8n` service, no reverse proxy, Tailscale-only access.
- `deploy.sh` sourcing `.env` and `.infisical-identity.env`, authenticating to a self-hosted Infisical instance via Universal Auth, and injecting the `N8N_ENCRYPTION_KEY` / `N8N_DB_PASS` secrets at deploy time.
- Memory cgroups enabled on FrenchPie's kernel (`cgroup_enable=memory cgroup_memory=1`) so that the compose file's `mem_limit: 450m` is actually enforced.
- Dedicated Postgres role (`n8n_app`) and database (`n8n`) on Caesura, restricted via `pg_hba.conf`/`ufw` to the Tailscale CGNAT range.
- Owner account created; Community Edition multi-user support documented (manual invite-link flow, no SMTP configured).
- Documentation: bilingual `README.md`/`README.fr.md`, `docs/troubleshooting.md`/`.fr.md`, `docs/architecture.md`/`.fr.md`, `SECURITY.md`, MIT `LICENSE`.

### Known issues

- Intermittent `Database ping failed: Database connection timed out` messages observed in `docker logs n8n`, most likely tied to the Tailscale link between FrenchPie and Caesura occasionally going through a DERP relay rather than a direct peer connection. Not yet confirmed or resolved — see `docs/troubleshooting.md` item 8 and the README's "Post-deployment TODO".
