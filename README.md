*[Version française](README.fr.md)*

# n8n — FrenchPie

Workflow automation (n8n), hosted on a Raspberry Pi 3B+ (named **FrenchPie** here), with the database on the **shared PostgreSQL 17** instance of another homelab host (named **Caesura** here) reached via Tailscale. Tailscale-only access, no public exposure.

IPs, hostnames and the Tailscale domain below are anonymized as placeholders (`<...>`) in this README and in `.env.example` — the real values only live in `.env` and `.infisical-identity.env`, both git-ignored.

## Architecture

```
Browser / mobile app (Tailscale client)
        │  http://<N8N_HOST_TAILSCALE_IP>:5678
        ▼
   n8n container (FrenchPie, host port 5678)
        │  outbound connection over the tailnet
        ▼
   Native Postgres 17 on Caesura (<CAESURA_TAILSCALE_IP>:5432, "n8n" database)
```

Unlike a deployment where Postgres runs on the *same* machine as the containers (which requires the `extra_hosts`/custom gateway workaround), Postgres here is remote — the n8n container reaches Caesura's Tailscale IP directly through Docker's standard outbound NAT, since FrenchPie itself is on the tailnet.

No Traefik here: FrenchPie doesn't run one, and access stays Tailscale-only so no reverse proxy is needed.

## Prerequisites

- A host (FrenchPie here) with Docker installed, on the same tailnet as the Postgres host
- A shared Postgres instance reachable over Tailscale (or any other Postgres reachable from FrenchPie)
- A self-hosted (or cloud) [Infisical](https://infisical.com/) instance for secrets management, with a project containing a `prod` environment
- The `infisical` CLI installed on the machine that runs `deploy.sh` (can be FrenchPie itself, or another machine driving Docker remotely via `DOCKER_HOST`/`docker context`)

## Pre-deployment checks (reference, on the Pi 3B+ used here)

- Architecture: `aarch64` (64-bit) → the official `n8nio/n8n` image is compatible (a 32-bit `armv7l` image is not)
- RAM: **tight on a Pi 3B+** — 905 Mi total, ~700 Mi available, 210 Mi free at idle. Swap unused at the start (a safety net, but slow on an SD card)
- Disk: a few GB free on `/`, enough for the image plus n8n's data
- Port 5678: check it's free (`sudo ss -tulpn | grep 5678`)
- Tailscale connectivity to the Postgres host: `tailscale ping <postgres-hostname>` should respond (see below if the response goes through a DERP relay)

## Deployment steps

### 1. Install Docker on the target host

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker <user>
# log out/in over SSH for the docker group membership to take effect
```

### 2. Enable memory cgroups (Raspberry Pi OS / Debian, often disabled by default)

Without this, `mem_limit` in the compose file is **silently ignored** (Docker shows `WARNING: No memory limit support` / `No swap limit support` in `docker info`):

```bash
sudo nano /boot/firmware/cmdline.txt
```
Append to the end of the line (space-separated, all on one line):
```
cgroup_enable=memory cgroup_memory=1
```
Then:
```bash
sudo reboot
```
After reboot, verify:
```bash
cat /proc/cmdline                    # must contain both flags
cat /sys/fs/cgroup/cgroup.controllers # must list "memory"
docker info | grep -i "memory\|swap" # the WARNING lines should be gone
```

### 3. On the Postgres host — create the database

```bash
openssl rand -hex 32   # generates the app password, keep it aside
sudo -u postgres psql -c "CREATE USER n8n_app WITH PASSWORD '<generated_password>';"
sudo -u postgres psql -c "CREATE DATABASE n8n OWNER n8n_app;"
```

### 4. On the Postgres host — allow the n8n host to connect

Check `pg_hba.conf`: if a rule already covers the whole Tailscale CGNAT range (`100.64.0.0/10`, the range used by every IP on a tailnet), there's nothing to add. Otherwise, add a line for the n8n host's specific Tailscale IP:
```
host    n8n    n8n_app    <N8N_HOST_TAILSCALE_IP>/32    scram-sha-256
```
```bash
sudo systemctl reload postgresql
sudo ufw allow from <N8N_HOST_TAILSCALE_IP> to any port 5432 proto tcp
```

### 5. Create the Infisical Machine Identity

In Infisical → your secrets project → Access Control → Machine Identities → **Create Identity**
- Name: `n8n-deploy`
- Auth method: Universal Auth
- Role: read access (`Viewer`) on the `prod` environment

⚠️ **Gotcha**: once the identity is created, its "Details" page shows an **"ID"** field — this is **NOT** the Client ID to use. You have to click the "Universal Auth" row in the Authentication section to open its configuration panel, which shows the **actual "Client ID"** (different from the identity's own ID) as well as the list of **Client Secrets**. Use the ID shown *inside that panel* — mixing the two up produces a 401 `Invalid credentials` error with no hint as to the real cause.

Generate a Client Secret from that same panel (**"Add Client Secret"**) — it's shown only once, copy it immediately.

### 6. Add the 2 application secrets to Infisical (`prod` environment)

- `N8N_ENCRYPTION_KEY` → generate with `openssl rand -hex 32` — **never lose or rotate it afterwards**, or every credential stored in your workflows becomes unreadable
- `N8N_DB_PASS` → the password created in step 3

### 7. Install the Infisical CLI (on the machine that will run `deploy.sh`)

```bash
curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | sudo -E bash
sudo apt install infisical
```

### 8. Configure the deployment folder

```bash
cp .env.example .env
# edit .env: Tailscale IPs of both hosts, Infisical domain, Infisical project ID

cp .infisical-identity.env.example .infisical-identity.env
# edit .infisical-identity.env with the Client ID (the one from the Universal Auth
# panel, not the identity's own ID) and the Client Secret from step 5
```

### 9. Deploy

**Option A — directly on the target host** (SSH into it, `cd` into this folder, then):
```bash
./deploy.sh
```

**Option B — remotely, from another machine, via an SSH Docker context** (avoids transferring the folder — deploy from wherever it lives, targeting the remote host):
```bash
export DOCKER_HOST="ssh://<user>@<TARGET_HOST_TAILSCALE_IP>"
./deploy.sh
```
⚠️ **Gotcha**: if `DOCKER_HOST` is already exported elsewhere (`.bashrc`, shell profile) pointing at a *different* machine, it takes precedence over `docker context use` / `DOCKER_CONTEXT` — Docker itself warns about this (`DOCKER_HOST environment variable overrides the active context`). Overriding `DOCKER_HOST` directly for the current session (as above) is more reliable than creating a named context in that case.

Pulling the image (~260 MB) can take **several tens of minutes** on a Pi 3B+ with a slow SD card — that's not a hang, just slow hardware. Check progress with `docker ps -a` / `docker logs n8n --tail 30` in a second terminal rather than interrupting it.

### 10. First access

`http://<N8N_HOST_TAILSCALE_IP>:5678` — from any device on the tailnet.

⚠️ **Gotcha**: on first startup, n8n runs through **hundreds of DB migrations** one by one, each a network round-trip to Postgres — this can take several extra minutes on top of the container's own startup. If the page shows "n8n is starting up. Please wait", that's normal, just wait.

If submitting the owner account setup form returns a `503 Database is not ready!` error, that isn't necessarily a failure. Check the logs (`docker logs n8n --tail 30`) — if the line `Owner was set up successfully` appears despite the error shown in the browser, the account was in fact created (the request succeeded server-side right after a transient DB timeout). Log in directly at `/signin` with the credentials you entered instead of redoing the setup.

## Multi-user

n8n Community Edition (unlicensed, which is the case here) supports multiple user accounts: **Settings → Users → Invite**. Without SMTP configured (not the case here), n8n generates an **invite link** to copy and send manually instead of emailing it — the invited person sets their own password by clicking it. Fine-grained sharing of workflows/credentials between accounts is more limited in Community Edition (advanced permission features are Enterprise-only).

## Post-deployment TODO

- [ ] Watch `docker stats n8n` for the first 24-48h — RAM is the most likely thing to cause trouble on constrained hardware (e.g. a Pi 3B+)
- [ ] Confirm the "n8n" database is covered by the existing Postgres backup strategy on the DB host
- [ ] If the n8n host has no backup mechanism of its own, add the `n8n-data` volume (holds the encryption key and local data) to a backup strategy
- [ ] If `Database ping failed: Database connection timed out` messages (visible in `docker logs`) persist under normal use (not just at startup), check whether the Tailscale link between the two hosts goes through a DERP relay rather than direct (`tailscale ping <host>`) — a relayed link adds variable latency that can time out DB requests under load
- [ ] If public exposure is ever needed (inbound webhooks from third-party services): revisit the whole architecture (Traefik, tunnel, `N8N_SECURE_COOKIE`, `WEBHOOK_URL`)

## Points of attention / gotchas encountered

1. **Memory cgroups disabled by default** on some Raspberry Pi OS/Debian images — the compose file's `mem_limit` is ignored without `cgroup_enable=memory cgroup_memory=1` in `cmdline.txt` (+ reboot). See step 2.
2. **`N8N_SECURE_COOKIE=false` is required** as long as there's no TLS in front of n8n (plain HTTP, Tailscale-only) — otherwise the session cookie is rejected and login silently breaks.
3. **`extra_hosts: host.docker.internal:host-gateway` doesn't work** on a custom Docker network if Postgres ever runs locally on the same host as n8n (a different case from this deployment, where Postgres is remote) — always hardcode the custom network's real gateway in that case.
4. **`N8N_ENCRYPTION_KEY` must never be rotated afterwards** without a migration plan — it's the key that decrypts every credential stored in existing workflows.
5. **Two different IDs on an Infisical Machine Identity**: the "ID" shown on the identity's details page is not the "Client ID" of its Universal Auth method (only visible by opening the "Universal Auth" panel). Mixing them up gives a 401 `Invalid credentials` with no useful hint. See step 5.
6. **`DOCKER_HOST` overrides `DOCKER_CONTEXT`** — if the `DOCKER_HOST` environment variable is already set (shell profile), `export DOCKER_CONTEXT=<name>` alone changes nothing as long as `DOCKER_HOST` stays set. Docker flags this with an explicit warning.
7. **Secrets managed via Infisical**, never a plaintext password in `.env` or committed — see `deploy.sh`.
8. **Slow image pull and migrations on constrained hardware** (Pi 3B+, SD card) — several tens of minutes for the pull, several minutes for DB migrations on first startup. Patience rather than interruption.

## Status

✅ Deployed and working — `n8n` container up, connection to the remote Postgres working, owner account created.
⬜ To keep an eye on: stability of the Tailscale connection to the Postgres host under sustained use (see "Post-deployment TODO").
