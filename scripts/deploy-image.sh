#!/usr/bin/env bash
# Deploy a code change to production Postiz.
#
# Two modes:
#   1. pull-mode (default): pulls the latest tagged image from ghcr.io on the droplet
#      and recreates the container. Use this when the image has already been built
#      and pushed (manually, or via a future CI workflow).
#
#   2. git-mode (--via-git): runs `git pull` inside /opt/postiz and then rebuilds the
#      image on the droplet itself. Mirrors the original "hotwired" deploy path —
#      kept here so we have one documented way to do it.

set -euo pipefail

SSH_HOST="${POSTIZ_SSH_HOST:-postiz}"
REMOTE_DIR="/opt/postiz"
COMPOSE="docker compose -f docker-compose.yaml -f docker-compose.prod.override.yaml"
MODE="pull"

BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
die() { printf "%s%s%s\n" "$RED" "$*" "$RESET" >&2; exit 1; }
info() { printf "%s%s%s\n" "$BOLD" "$*" "$RESET"; }

for arg in "$@"; do
  case "$arg" in
    --via-git) MODE="git" ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--via-git]

Default (no flag): pulls the latest tagged ghcr.io image on the droplet and recreates postiz.
--via-git:         git pull on the droplet, then recreate postiz (image rebuilt from source).

Env overrides:
  POSTIZ_SSH_HOST   SSH alias or user@host (default: postiz)
EOF
      exit 0
      ;;
    *) die "Unknown arg: $arg (use --help)" ;;
  esac
done

ssh -o BatchMode=yes -o ConnectTimeout=8 "$SSH_HOST" true 2>/dev/null \
  || die "Cannot ssh to '$SSH_HOST'."

printf "%sDeploy postiz image to %s (mode: %s)? [y/N] %s" "$YELLOW" "$SSH_HOST" "$MODE" "$RESET"
read -r confirm
[[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted."

if [[ "$MODE" == "git" ]]; then
  info "Pulling latest fork code on droplet..."
  ssh "$SSH_HOST" "cd $REMOTE_DIR && git pull --ff-only"
else
  info "Pulling latest postiz image on droplet..."
  ssh "$SSH_HOST" "cd $REMOTE_DIR && $COMPOSE pull postiz"
fi

info "Recreating postiz container..."
ssh "$SSH_HOST" "cd $REMOTE_DIR && $COMPOSE up -d --no-deps --force-recreate postiz"

info "Tailing postiz logs for 20s to confirm clean boot..."
ssh "$SSH_HOST" "cd $REMOTE_DIR && timeout 20 $COMPOSE logs --tail=30 --follow postiz" || true

info "${GREEN}Done.${RESET}"
