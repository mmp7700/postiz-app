#!/usr/bin/env bash
# Sync .env.prod between this repo and the production Postiz droplet.
#
# Subcommands:
#   pull   - copy remote /opt/postiz/.env down to ./.env.prod
#   diff   - show key-level diff between local .env.prod and remote .env (values masked)
#   push   - back up remote, rsync local up, recreate postiz container, tail logs

set -euo pipefail

SSH_HOST="${POSTIZ_SSH_HOST:-postiz}"
REMOTE_DIR="/opt/postiz"
REMOTE_ENV="${REMOTE_DIR}/.env"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_ENV="${REPO_ROOT}/.env.prod"
COMPOSE="docker compose -f docker-compose.yaml -f docker-compose.prod.override.yaml"

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'

die() { printf "%s%s%s\n" "$RED" "$*" "$RESET" >&2; exit 1; }
info() { printf "%s%s%s\n" "$BOLD" "$*" "$RESET"; }

check_ssh() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$SSH_HOST" true 2>/dev/null \
    || die "Cannot ssh to '$SSH_HOST'. Check ~/.ssh/config (should define Host postiz) or set POSTIZ_SSH_HOST."
}

mask_values() {
  sed -E 's/^([A-Z_][A-Z0-9_]*)=.*/\1=<value>/'
}

extract_keys() {
  grep -E '^[A-Z_][A-Z0-9_]*=' "$1" | sort
}

cmd_pull() {
  check_ssh
  if [[ -f "$LOCAL_ENV" ]]; then
    cp "$LOCAL_ENV" "${LOCAL_ENV}.bak.$(date +%Y%m%d-%H%M%S)"
    info "Backed up existing local .env.prod"
  fi
  rsync -e ssh -avz "$SSH_HOST:$REMOTE_ENV" "$LOCAL_ENV"
  info "Pulled $REMOTE_ENV → $LOCAL_ENV"
}

cmd_diff() {
  check_ssh
  [[ -f "$LOCAL_ENV" ]] || die "$LOCAL_ENV does not exist. Run './scripts/deploy-env.sh pull' to bootstrap it."
  local remote_tmp
  remote_tmp=$(mktemp)
  trap "rm -f $remote_tmp" EXIT
  ssh "$SSH_HOST" "cat $REMOTE_ENV" > "$remote_tmp"

  info "Key-level diff (values masked) — local vs remote:"
  local local_masked remote_masked
  local_masked=$(extract_keys "$LOCAL_ENV" | mask_values)
  remote_masked=$(extract_keys "$remote_tmp" | mask_values)
  if diff <(echo "$remote_masked") <(echo "$local_masked") > /dev/null; then
    info "${GREEN}No key changes. Local and remote have the same set of variables.${RESET}"
  else
    diff -u --label "remote (${REMOTE_ENV})" --label "local (.env.prod)" \
      <(echo "$remote_masked") <(echo "$local_masked") || true
  fi

  printf "\n%sValue-level changes (key names of vars whose values differ):%s\n" "$BOLD" "$RESET"
  local changed
  changed=$(diff <(extract_keys "$remote_tmp") <(extract_keys "$LOCAL_ENV") | grep -E '^[<>]' | awk '{print $2}' | cut -d= -f1 | sort -u || true)
  if [[ -z "$changed" ]]; then
    printf "  %s(none)%s\n" "$DIM" "$RESET"
  else
    printf "%s\n" "$changed" | sed 's/^/  /'
  fi
}

cmd_push() {
  check_ssh
  [[ -f "$LOCAL_ENV" ]] || die "$LOCAL_ENV does not exist. Run './scripts/deploy-env.sh pull' first."

  cmd_diff

  printf "\n%sApply above changes to %s%s? [y/N] %s" "$YELLOW" "$SSH_HOST" "$RESET" ""
  read -r confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted."

  info "Backing up remote .env on droplet..."
  ssh "$SSH_HOST" "ts=\$(date +%Y%m%d-%H%M%S) && cp '$REMOTE_ENV' '${REMOTE_ENV}.bak.'\$ts"

  info "Syncing local .env.prod → remote $REMOTE_ENV..."
  rsync -e ssh -avz "$LOCAL_ENV" "$SSH_HOST:$REMOTE_ENV"

  info "Recreating postiz container (will not touch postgres/redis/temporal)..."
  ssh "$SSH_HOST" "cd $REMOTE_DIR && $COMPOSE up -d --no-deps --force-recreate postiz"

  info "Tailing postiz logs for 15s to confirm clean boot..."
  ssh "$SSH_HOST" "cd $REMOTE_DIR && timeout 15 $COMPOSE logs --tail=30 --follow postiz" || true

  info "${GREEN}Done.${RESET} Recent remote backups:"
  ssh "$SSH_HOST" "ls -lt $REMOTE_DIR/.env.bak.* 2>/dev/null | head -5"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") {pull|diff|push}

  pull   Copy remote $REMOTE_ENV → local .env.prod
  diff   Show what would change (values masked)
  push   Back up remote, sync up, recreate postiz container, tail logs

Env overrides:
  POSTIZ_SSH_HOST   SSH alias or user@host (default: postiz)
EOF
  exit 1
}

case "${1:-}" in
  pull) cmd_pull ;;
  diff) cmd_diff ;;
  push) cmd_push ;;
  *)    usage ;;
esac
