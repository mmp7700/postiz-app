#!/usr/bin/env bash
# Push docker-compose.prod.override.yaml + the patches/ directory to the
# production droplet, then recreate the postiz container.
#
# Use this for changes that aren't secrets:
#   - Override YAML edits (port mappings, volume mounts, etc.)
#   - Updated patch files in patches/
#
# Subcommands:
#   diff   - byte-level diff of local vs remote override (and patches/)
#   push   - back up remote, sync up, recreate postiz, tail logs

set -euo pipefail

SSH_HOST="${POSTIZ_SSH_HOST:-postiz}"
REMOTE_DIR="/opt/postiz"
REMOTE_OVERRIDE="${REMOTE_DIR}/docker-compose.prod.override.yaml"
REMOTE_PATCHES="${REMOTE_DIR}/patches"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_OVERRIDE="${REPO_ROOT}/docker-compose.prod.override.yaml"
LOCAL_PATCHES="${REPO_ROOT}/patches"
COMPOSE="docker compose -f docker-compose.yaml -f docker-compose.prod.override.yaml"

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
die() { printf "%s%s%s\n" "$RED" "$*" "$RESET" >&2; exit 1; }
info() { printf "%s%s%s\n" "$BOLD" "$*" "$RESET"; }

check_ssh() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$SSH_HOST" true 2>/dev/null \
    || die "Cannot ssh to '$SSH_HOST'."
}

cmd_diff() {
  check_ssh
  [[ -f "$LOCAL_OVERRIDE" ]] || die "$LOCAL_OVERRIDE does not exist."

  info "--- override.yaml diff (remote vs local) ---"
  ssh "$SSH_HOST" "cat $REMOTE_OVERRIDE" | diff -u --label "remote" --label "local" - "$LOCAL_OVERRIDE" || true

  info "--- patches/ rsync dry-run ---"
  rsync -e ssh -avzn --delete "$LOCAL_PATCHES/" "$SSH_HOST:$REMOTE_PATCHES/" | grep -vE '^$|^sending|^total|^sent' || true
}

cmd_push() {
  check_ssh
  [[ -f "$LOCAL_OVERRIDE" ]] || die "$LOCAL_OVERRIDE does not exist."
  [[ -d "$LOCAL_PATCHES" ]] || die "$LOCAL_PATCHES does not exist."

  info "Validating with docker compose config..."
  if ! (cd "$REPO_ROOT" && $COMPOSE --env-file "$REPO_ROOT/.env.prod" config > /dev/null 2>&1); then
    die "Local docker compose config failed. Run 'docker compose -f docker-compose.yaml -f docker-compose.prod.override.yaml --env-file .env.prod config' to see why."
  fi

  cmd_diff

  printf "\n%sApply override + patches/ changes to %s and recreate postiz? [y/N] %s" "$YELLOW" "$SSH_HOST" "$RESET"
  read -r confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted."

  info "Backing up remote override..."
  ssh "$SSH_HOST" "ts=\$(date +%Y%m%d-%H%M%S) && cp '$REMOTE_OVERRIDE' '${REMOTE_OVERRIDE}.bak.'\$ts"

  info "Syncing override..."
  rsync -e ssh -avz "$LOCAL_OVERRIDE" "$SSH_HOST:$REMOTE_OVERRIDE"

  info "Syncing patches/ (--delete removes stale patches no longer in repo)..."
  rsync -e ssh -avz --delete "$LOCAL_PATCHES/" "$SSH_HOST:$REMOTE_PATCHES/"

  info "Recreating postiz container..."
  ssh "$SSH_HOST" "cd $REMOTE_DIR && $COMPOSE up -d --no-deps --force-recreate postiz"

  info "Tailing postiz logs for 20s..."
  ssh "$SSH_HOST" "cd $REMOTE_DIR && timeout 20 $COMPOSE logs --tail=30 --follow postiz" || true

  info "${GREEN}Done.${RESET}"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") {diff|push}

  diff   Show diff of override + patches/ vs remote
  push   Validate, prompt, back up remote, sync both, recreate postiz, tail logs

Env overrides:
  POSTIZ_SSH_HOST   SSH alias or user@host (default: postiz)
EOF
  exit 1
}

case "${1:-}" in
  diff) cmd_diff ;;
  push) cmd_push ;;
  *)    usage ;;
esac
