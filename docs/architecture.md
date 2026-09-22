*[Version française](architecture.fr.md)*

# Architecture

This document goes deeper than the README's overview: how the pieces fit together, and why each design choice was made.

## Network flow

```
Browser / mobile app (Tailscale client, anywhere on the tailnet)
        │
        │  HTTP, port 5678
        ▼
Raspberry Pi 3B+ "FrenchPie" (Tailscale IP <N8N_HOST_TAILSCALE_IP>)
        │
        │  Docker: host port 5678 → container port 5678 (bridge network, standard port mapping)
        ▼
   n8n container
        │
        │  outbound TCP, port 5432, over the tailnet (Docker's default outbound NAT — no special config)
        ▼
"Caesura" host (Tailscale IP <CAESURA_TAILSCALE_IP>)
        │
        ▼
   Native PostgreSQL 17 process (not containerized), database "n8n", user "n8n_app"
```

Two Tailscale-connected hosts, two different roles: FrenchPie runs the application, Caesura runs the shared database that several projects in this homelab use (n8n is one tenant among others on that same Postgres instance).

## Why no Traefik

Every other service in this homelab collection sits behind Traefik for automatic HTTPS and routing. n8n on FrenchPie does not, for two reasons:

- FrenchPie doesn't run a Traefik instance of its own, and adding one just for a single Tailscale-only service isn't worth the overhead on a Pi 3B+ with 1&nbsp;GB of RAM.
- Access is Tailscale-only. Every client reaching n8n is already authenticated by Tailscale's own network layer (WireGuard-based, identity-bound). There's no public surface to protect with TLS termination, so plain HTTP on the tailnet is an acceptable trade-off here — it would not be if this were ever exposed publicly (see the README's "if public exposure is needed" TODO item).

## Why Postgres stays remote (on Caesura, not FrenchPie)

Two practical reasons:

- **Hardware.** A Pi 3B+ with 1&nbsp;GB of RAM and an SD card is a poor host for a database — SD cards degrade under sustained write load, and RAM is already tight just for n8n itself (see the README's pre-deployment RAM numbers).
- **Consolidation.** Caesura already runs a shared Postgres 17 instance used by other projects in this homelab. Adding one more database (`n8n`, owned by a dedicated `n8n_app` user, isolated from other databases on the same instance) is cheaper to operate and back up than standing up a second Postgres instance on a machine that struggles to run anything else.

This is also why this deployment needs no `extra_hosts: host.docker.internal:host-gateway` trick: that workaround exists for when a container needs to reach a service on its *own* host through the Docker bridge's gateway IP. Here, Postgres is on a different machine entirely, reached over the tailnet like any other remote host — Docker's default outbound NAT handles it with zero special configuration.

## Docker networking specifics

- No custom Docker network is defined; n8n uses the default bridge network created for the container.
- The `ports: - "5678:5678"` mapping in `docker-compose.yml` publishes the container's port directly to FrenchPie's host network, which is itself on the tailnet. This is what makes `http://<N8N_HOST_TAILSCALE_IP>:5678` reachable from anywhere else on the tailnet.
- Outbound traffic to Postgres (`DB_POSTGRESDB_HOST=<CAESURA_TAILSCALE_IP>`) leaves the container through Docker's standard outbound NAT, reaches FrenchPie's `tailscale0` interface, and is routed over the tailnet to Caesura — same as if any other process on FrenchPie opened that connection directly.

## cgroups and `mem_limit`

Raspberry Pi OS (like several other minimal/embedded Debian derivatives) ships with the kernel's memory cgroup controller **disabled by default**, to save a small amount of boot-time and runtime overhead. Docker's `mem_limit` directive in `docker-compose.yml` (set to `450m` here, deliberately conservative on a 1&nbsp;GB machine also running the OS and Docker itself) depends entirely on that controller: without it, Docker silently accepts the directive but never enforces it (visible as `WARNING: No memory limit support` in `docker info`).

Enabling it requires a kernel boot parameter change (`cgroup_enable=memory cgroup_memory=1` in `/boot/firmware/cmdline.txt`) and a reboot — a one-time, host-level change independent of the n8n deployment itself. See the README's step 2 and `docs/troubleshooting.md` item 1 for the concrete commands.

## Secrets flow at deploy time

No secret is ever written to disk in plaintext as part of this deployment's own files (`.env` and `.infisical-identity.env` hold only identifiers, credentials for Infisical itself, and connection parameters — not the application secrets `N8N_ENCRYPTION_KEY` / `N8N_DB_PASS`, both of which live only inside Infisical).

`deploy.sh` does the following at every deploy:

1. Sources `.infisical-identity.env` (Machine Identity Client ID/Secret) and `.env` (Infisical domain, project ID, plus the non-secret `N8N_HOST`/`DB_HOST` values).
2. Authenticates to Infisical via `infisical login --method=universal-auth`, obtaining a short-lived Infisical access token — this step never touches the application secrets themselves, only proves the deploying machine's identity to Infisical.
3. Runs `infisical run ... -- docker compose up -d`: the Infisical CLI fetches the `prod`-environment secrets (`N8N_ENCRYPTION_KEY`, `N8N_DB_PASS`) at that moment, injects them as environment variables into the `docker compose up` process only, and they flow from there into the container's environment through the `${...}` references in `docker-compose.yml`.

The secrets exist in plaintext only transiently, in the memory of the `docker compose up` process and the resulting container's environment — never written to a file on FrenchPie's disk as part of this deployment's own tooling, and never committed to version control.
