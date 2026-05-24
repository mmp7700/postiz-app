# Deploying Postiz to production

Production runs on a dedicated DigitalOcean droplet aliased "Postiz" (164.90.140.54), provisioned via Appliku. The Postiz container itself is **not** an Appliku-managed app — Appliku handles SSL/reverse-proxy and droplet hosting, while the Postiz stack is a normal Docker Compose project at `/opt/postiz/`.

## Prerequisites

- SSH access via `ssh postiz` (defined in `~/.ssh/config`, key at `~/.ssh/id_ed25519_postiz`)
- A local `.env.prod` at repo root (gitignored). Bootstrap with `pnpm deploy:env:pull` if missing.
- Local `docker compose` available (for pre-push validation)

## Three kinds of deploy

The deploy is split into three primitives so each kind of change is small and reversible. Pick whichever fits.

### 1. Changing environment variables (most common)

Edit secrets and config in `.env.prod` locally, sync up.

```bash
pnpm deploy:env:pull    # bootstrap, or after manual changes on the droplet
$EDITOR .env.prod
pnpm deploy:env:diff    # preview key-level changes (values masked)
pnpm deploy:env         # backup remote, sync up, recreate postiz, tail logs
```

### 2. Changing the compose override or the JS patches

When you edit `docker-compose.prod.override.yaml` (e.g., new env var mapping, port change, volume mount) or update a file in `patches/`:

```bash
pnpm deploy:compose:diff   # show diff of override + patches/ vs remote
pnpm deploy:compose        # validate, prompt, backup, sync both, recreate, tail logs
```

`deploy:compose` validates locally with `docker compose config --env-file .env.prod` before pushing. It also `--delete`s patch files from the droplet that you've removed locally, so the droplet stays in sync.

### 3. Deploying new Postiz image code

When you've rebuilt `ghcr.io/mmp7700/postiz-app:borderline` and need prod to pick it up:

```bash
pnpm deploy:image         # docker compose pull + recreate postiz
pnpm deploy:image:git     # git pull on droplet + recreate (for source-built environments)
```

Every primitive only recreates the `postiz` service. Postgres, Redis, Temporal, and the Appliku nginx stay untouched.

## What lives where

| Path | Purpose | Source of truth |
| --- | --- | --- |
| `/opt/postiz/` on droplet | Repo checkout — compose project root | `mmp7700/postiz-app` on GitHub |
| `/opt/postiz/.env` on droplet | Live env vars consumed by the postiz container | `.env.prod` in this repo (gitignored) |
| `/opt/postiz/docker-compose.prod.override.yaml` on droplet | Prod-only compose overlay (image tag, ports, volumes, env mappings) | This repo (committed) |
| `/opt/postiz/patches/` on droplet | Bind-mounted JS patches for LinkedIn dual-app support | `patches/` in this repo (committed; see `patches/README.md`) |
| `/home/app/_nginx/` on droplet | Appliku-managed nginx + Let's Encrypt | Appliku |

The override and patches/ are reproducible from GitHub. The `.env.prod` is the only thing not in the repo — keep a backup in your password manager.

## Reproducing this deploy on a new droplet

If the current droplet ever dies:

1. Provision a new droplet via Appliku, register it as a server in the borderline team. Adjust DNS so `social.itsborderline.com` points to the new IP.
2. `ssh root@<new-ip>`, `git clone https://github.com/mmp7700/postiz-app.git /opt/postiz`, `cd /opt/postiz`.
3. Drop your password-manager copy of `.env` into `/opt/postiz/.env`.
4. `docker compose -f docker-compose.yaml -f docker-compose.prod.override.yaml up -d`.

That's it — patches and override come down with the clone.

## Rollbacks

Every deploy primitive backs up the file(s) it changes on the droplet, with a timestamped suffix:

- `/opt/postiz/.env.bak.YYYYMMDD-HHMMSS`
- `/opt/postiz/docker-compose.prod.override.yaml.bak.YYYYMMDD-HHMMSS`

To restore one:

```bash
ssh postiz "ls -lt /opt/postiz/.env.bak.* | head"
ssh postiz "cp /opt/postiz/.env.bak.YYYYMMDD-HHMMSS /opt/postiz/.env"
ssh postiz "cd /opt/postiz && docker compose -f docker-compose.yaml -f docker-compose.prod.override.yaml up -d --no-deps --force-recreate postiz"
```

## What to never do

- Edit `/opt/postiz/.env` or the override directly on the droplet without pulling locally first — local drift will be silently overwritten on the next push.
- Touch `/home/app/_nginx/` — that's Appliku's domain.
- Run `docker compose down` on the droplet without intent — it stops postgres too.
- Hand-edit files in `/opt/postiz/patches/` on the droplet. Edit `patches/` in the repo and `pnpm deploy:compose` instead.
