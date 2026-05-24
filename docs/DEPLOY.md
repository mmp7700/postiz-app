# Deploying Postiz to production

Production runs on a dedicated DigitalOcean droplet aliased "Postiz" (164.90.140.54), provisioned via Appliku. The Postiz container itself is **not** an Appliku-managed app — Appliku handles SSL/reverse-proxy and droplet hosting, while the Postiz stack is a normal Docker Compose project at `/opt/postiz/`.

## Prerequisites

- SSH access via `ssh postiz` (defined in `~/.ssh/config`, key at `~/.ssh/id_ed25519_postiz`)
- A local `.env.prod` at repo root (gitignored). Bootstrap with `./scripts/deploy-env.sh pull`.

## Updating environment variables

The most common deploy. Edit locally, sync up.

```bash
./scripts/deploy-env.sh pull    # one-time bootstrap, or after manual changes on the droplet
$EDITOR .env.prod
./scripts/deploy-env.sh diff    # preview key-level changes (values masked)
./scripts/deploy-env.sh push    # backup remote, sync up, recreate postiz, tail logs
```

`push` only recreates the `postiz` service. Postgres, Redis, Temporal, and the Appliku nginx stay untouched.

A timestamped backup of the prior remote `.env` is left at `/opt/postiz/.env.bak.YYYYMMDD-HHMMSS`. Roll back by SSHing in and `mv`'ing it back.

## Updating Postiz code (custom fork)

When you rebuild `ghcr.io/mmp7700/postiz-app:borderline` and need prod to pick it up:

```bash
./scripts/deploy-image.sh          # docker compose pull + recreate
./scripts/deploy-image.sh --via-git # git pull on droplet + recreate (rebuilds from source)
```

## What lives where on the droplet

| Path | Purpose |
| --- | --- |
| `/opt/postiz/` | Full repo checkout (also contains `docker-compose.yaml` + `.prod.override.yaml`) |
| `/opt/postiz/.env` | Live env vars consumed by the Postiz container |
| `/home/app/_nginx/` | Appliku-managed nginx reverse proxy + Let's Encrypt certs |

## What to never do

- Edit `/opt/postiz/.env` directly on the droplet without pulling locally first — local drift will be silently overwritten on the next `push`.
- Touch `/home/app/_nginx/` — that's Appliku's domain.
- Run `docker compose down` on the droplet without intent — it stops postgres too.
