# Security Policy

This is a personal homelab project, shared publicly for reference and documentation purposes. It is not a maintained open-source project with a formal support lifecycle, but security-relevant reports are still welcome.

## Scope

This repository contains deployment configuration (Docker Compose, a deploy script, documentation) for running [n8n](https://n8n.io/) with a remote PostgreSQL database over a private Tailscale network. It does not contain the n8n application itself, nor any real credentials, IP addresses, or domain names — those live only in git-ignored local files (`.env`, `.infisical-identity.env`) and a private Infisical instance, and every example/placeholder value in the committed files has been verified not to leak real infrastructure details.

If you find that a real secret, IP address, hostname, or other sensitive value was accidentally committed to this repository, please report it privately (see below) rather than opening a public issue, so it can be rotated and removed from history before wider disclosure.

For anything else — a real vulnerability in **n8n** itself, or in **PostgreSQL**, **Docker**, **Infisical**, or **Tailscale** — please report it to the respective upstream project instead; this repository has no ability to patch those.

## Reporting a vulnerability or a leaked secret

Please open a GitHub issue on this repository marked clearly as security-sensitive, or, if the report itself contains sensitive details (a real leaked value, for example), use GitHub's private vulnerability reporting feature on this repository instead of a public issue.

There is no fixed response-time commitment, but reports will be looked at and acknowledged as soon as reasonably possible — this is maintained on a best-effort basis alongside the rest of a personal homelab.

## Notes on this deployment's security posture

- Access to n8n is restricted to devices on the operator's [Tailscale](https://tailscale.com/) network (tailnet) — there is no public-facing port, and no reverse proxy or TLS termination is configured, by design (see `docs/architecture.md`).
- Application secrets (`N8N_ENCRYPTION_KEY`, the database password) are managed through a self-hosted [Infisical](https://infisical.com/) instance and injected only at deploy time — they are never stored in plaintext in this repository or on disk as part of this project's own files.
- Database access is restricted at the PostgreSQL (`pg_hba.conf`) and firewall (`ufw`) level to the Tailscale CGNAT address range.
