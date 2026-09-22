*[Version française](troubleshooting.fr.md)*

# Troubleshooting

Detailed notes on every issue hit while setting up this deployment — symptom, cause, and fix. Kept here rather than in the main README so the README stays a quick-start guide.

## 1. `docker info` shows `WARNING: No memory limit support` / `No swap limit support`

**Symptom**: the compose file's `mem_limit` doesn't seem to constrain the container at all — it can grow past the configured limit.

**Cause**: memory cgroups are disabled by default on some Raspberry Pi OS / Debian images to save a small amount of boot RAM.

**Fix**:
```bash
sudo nano /boot/firmware/cmdline.txt
```
Append to the end of the (single) line:
```
cgroup_enable=memory cgroup_memory=1
```
Reboot, then verify:
```bash
cat /proc/cmdline                    # must contain both flags
cat /sys/fs/cgroup/cgroup.controllers # must list "memory"
docker info | grep -i "memory\|swap" # the WARNING lines should be gone
```
Note: a leftover `cgroup_disable=memory` earlier on the same line (some default Pi images ship with it) does not necessarily block this — check `cgroup.controllers` as the source of truth rather than assuming the disable flag wins.

## 2. Login breaks silently over plain HTTP

**Symptom**: n8n's login form submits but nothing happens, no error shown, no session created.

**Cause**: n8n defaults to `Secure` session cookies, which browsers refuse to store over plain HTTP.

**Fix**: set `N8N_SECURE_COOKIE=false` in the environment — required as long as there's no TLS in front of n8n (Tailscale-only HTTP access, as in this deployment).

## 3. `extra_hosts: host.docker.internal:host-gateway` resolves to the wrong IP

**Symptom**: a container on a custom Docker network can't reach a service running on the host's Postgres (or anything else bound to the host) — connections silently time out.

**Cause**: the `host-gateway` magic value always resolves to the *default* bridge network's gateway (commonly `172.17.0.1`), never to a custom network's own gateway.

**Fix**: hardcode the actual gateway of the custom network instead:
```yaml
extra_hosts:
  - "host.docker.internal:172.x.x.1"   # the real gateway of your custom network
```
Not applicable to this specific deployment (Postgres is remote, reached over Tailscale, not via `host.docker.internal`) — documented here because it's a recurring gotcha across other services in the same homelab (Gitea/Woodpecker, both local-Postgres deployments).

## 4. `N8N_ENCRYPTION_KEY` loss makes all credentials unreadable

**Symptom**: after rotating or losing the encryption key, every credential stored in existing workflows fails to decrypt.

**Cause**: this key is what n8n uses to encrypt credentials at rest in Postgres — it's not derived from anything else and has no server-side backup by default.

**Fix**: there isn't one after the fact. Generate it once (`openssl rand -hex 32`), store it in Infisical (or another secret manager) as the single source of truth, and never regenerate it without a deliberate credential-migration plan.

## 5. Infisical Machine Identity: two different IDs

**Symptom**: `infisical login --method=universal-auth` fails with `401 Invalid credentials`, even though the Client ID and Secret were copied carefully.

**Cause**: a Machine Identity's details page shows an **"ID"** field at the top (the identity's own internal ID, used for role/access-control references) — this is a different value from the **"Client ID"** used for Universal Auth login, which only appears inside the "Universal Auth" configuration panel (click the "Universal Auth" row under Authentication).

**Fix**: always copy the Client ID from inside that panel, not from the identity's top-level "Details" card. The Client Secret shown in the same panel is correct either way.

## 6. `DOCKER_HOST` silently overrides `DOCKER_CONTEXT`

**Symptom**: `export DOCKER_CONTEXT=<name>` followed by `docker context show` still reports `default`, and `docker info` still targets the wrong host.

**Cause**: if the `DOCKER_HOST` environment variable is set anywhere in the shell's environment (commonly exported in `.bashrc`/`.bash_profile` for a "default" remote host), it takes precedence over context selection entirely. Docker actually prints an explicit warning about this on `docker context ls`.

**Fix**: for a one-off session targeting a different host, override `DOCKER_HOST` directly rather than fighting it via context:
```bash
export DOCKER_HOST="ssh://<user>@<target-host-tailscale-ip>"
```
This is scoped to the current shell only — other terminals and the persistent profile default are unaffected.

## 7. `503 Database is not ready!` on first owner-account setup

**Symptom**: submitting the "Set up owner account" form returns a `503` with `{"code":503,"message":"Database is not ready!"}`.

**Cause**: a transient Postgres connectivity hiccup (see #8) right at the moment of the request. The account creation can still complete server-side even though the HTTP response that reaches the browser is an error.

**Fix**: before retrying the form, check the container logs:
```bash
docker logs n8n --tail 50
```
If `Owner was set up successfully` appears despite the browser-side error, the account exists — log in directly at `/setup`'s sibling route, `/signin`, with the credentials just entered, instead of resubmitting setup (which would otherwise fail differently, since an owner already exists).

## 8. Recurring `Database ping failed: Database connection timed out`

**Symptom**: `docker logs n8n` repeatedly shows this message, alternating with `Database connection recovered` — the app keeps working, but the pattern recurs.

**Likely cause**: when the Tailscale link between the n8n host and the Postgres host is relayed through a DERP server rather than a direct peer-to-peer connection, latency becomes higher and more variable, which can trip Postgres client timeouts under load — especially right after a resource-heavy operation (e.g. a slow image pull on constrained hardware) that leaves the host and its network stack under pressure.

**Diagnosis**:
```bash
tailscale ping <postgres-host-name>
```
Look for `via DERP(...)` in the output (relayed) versus a direct IP (`via <ip>:<port>` without the DERP prefix — after the first one or two probe packets, which often go via DERP while the direct path is still being established).

**Fix / mitigation**: if consistently relayed, investigate why a direct connection isn't forming (commonly NAT/UPnP restrictions on one side's router — see Tailscale's [NAT traversal docs](https://tailscale.com/kb/1257/connection-types)). If it self-resolves to direct after the first few packets and the timeouts stop recurring under normal (non-startup) load, it's likely just startup-time resource pressure and not a lasting issue.

## 9. Slow image pulls and migrations on constrained hardware

**Symptom**: `deploy.sh` appears to hang for a long time on `Pulling` during `docker compose up`, or the first page load shows "n8n is starting up" for several minutes.

**Cause**: a Raspberry Pi 3B+ with an SD card is simply slow at decompressing a ~260 MB image, and n8n runs hundreds of sequential DB migrations on first start (each one a network round-trip to Postgres).

**Fix**: none needed — just patience. Use a second terminal to check progress without interrupting the first:
```bash
docker ps -a
docker logs n8n --tail 30
```
A pull time in the range of 15-20 minutes on this class of hardware is normal, not a hang.
