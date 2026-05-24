#!/usr/bin/env bash
# One-shot migration deploy: pushes BOTH .env.prod and the new committable
# docker-compose.prod.override.yaml to the droplet atomically, then recreates
# the postiz container.
#
# Use this script EXACTLY ONCE to transition from the old hot-wired override
# (with inlined secrets) to the new ${VAR}-substitution override. After this
# runs successfully, ongoing env changes go through scripts/deploy-env.sh and
# ongoing override changes go through scripts/deploy-compose.sh.
#
# Safety:
#   - Backs up BOTH remote files with timestamps before overwriting
#   - Refuses to proceed if local files don't validate via `docker compose config`
#   - Tails logs after recreate so failures are caught immediately
#   - Rollback instructions printed on failure

set -euo pipefail

SSH_HOST="${POSTIZ_SSH_HOST:-postiz}"
REMOTE_DIR="/opt/postiz"
REMOTE_ENV="${REMOTE_DIR}/.env"
REMOTE_OVERRIDE="${REMOTE_DIR}/docker-compose.prod.override.yaml"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_ENV="${REPO_ROOT}/.env.prod"
LOCAL_OVERRIDE="${REPO_ROOT}/docker-compose.prod.override.yaml"
COMPOSE="docker compose -f docker-compose.yaml -f docker-compose.prod.override.yaml"

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
die() { printf "%s%s%s\n" "$RED" "$*" "$RESET" >&2; exit 1; }
info() { printf "%s%s%s\n" "$BOLD" "$*" "$RESET"; }

[[ -f "$LOCAL_ENV" ]] || die "$LOCAL_ENV does not exist."
[[ -f "$LOCAL_OVERRIDE" ]] || die "$LOCAL_OVERRIDE does not exist."

ssh -o BatchMode=yes -o ConnectTimeout=8 "$SSH_HOST" true 2>/dev/null \
  || die "Cannot ssh to '$SSH_HOST'."

info "1/6  Validating local files with docker compose config..."
if ! (cd "$REPO_ROOT" && $COMPOSE --env-file "$LOCAL_ENV" config > /dev/null 2>&1); then
  die "Local docker compose config failed. Fix before deploying."
fi
printf "  %s✓%s parses cleanly\n" "$GREEN" "$RESET"

info "2/6  Showing what will change (counts only, no values):"
local_env_keys=$(grep -cE "^[A-Z_]+=" "$LOCAL_ENV")
local_override_size=$(wc -c < "$LOCAL_OVERRIDE")
remote_env_keys=$(ssh "$SSH_HOST" "grep -cE '^[A-Z_]+=' $REMOTE_ENV")
remote_override_size=$(ssh "$SSH_HOST" "wc -c < $REMOTE_OVERRIDE")
printf "  .env:        local %d keys → remote %d keys\n" "$local_env_keys" "$remote_env_keys"
printf "  override:    local %d bytes → remote %d bytes\n" "$local_override_size" "$remote_override_size"

printf "\n%sThis pushes BOTH files and recreates the postiz container.%s\n" "$YELLOW" "$RESET"
printf "%sBackups are made automatically. Proceed? [y/N] %s" "$YELLOW" "$RESET"
read -r confirm
[[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted."

info "3/6  Backing up remote files..."
ssh "$SSH_HOST" "
  ts=\$(date +%Y%m%d-%H%M%S) &&
  cp '$REMOTE_ENV'      '${REMOTE_ENV}.bak.migration.'\$ts &&
  cp '$REMOTE_OVERRIDE' '${REMOTE_OVERRIDE}.bak.migration.'\$ts &&
  echo \"  backed up to *.bak.migration.\$ts\"
"

info "4/6  Pushing both files (rsync)..."
rsync -e ssh -avz "$LOCAL_ENV"      "$SSH_HOST:$REMOTE_ENV"
rsync -e ssh -avz "$LOCAL_OVERRIDE" "$SSH_HOST:$REMOTE_OVERRIDE"

info "5/6  Recreating postiz container..."
ssh "$SSH_HOST" "cd $REMOTE_DIR && $COMPOSE up -d --no-deps --force-recreate postiz" || {
  printf "\n%sRecreate failed. To roll back:%s\n" "$RED" "$RESET"
  cat <<EOF
  ssh $SSH_HOST <<'ROLLBACK'
    cd $REMOTE_DIR
    LATEST_BAK=\$(ls -t .env.bak.migration.* | head -1)
    LATEST_OV=\$(ls -t docker-compose.prod.override.yaml.bak.migration.* | head -1)
    cp \$LATEST_BAK .env
    cp \$LATEST_OV docker-compose.prod.override.yaml
    $COMPOSE up -d --no-deps --force-recreate postiz
  ROLLBACK
EOF
  die "Container recreate failed."
}

info "6/6  Tailing postiz logs for 25s to confirm clean boot..."
ssh "$SSH_HOST" "cd $REMOTE_DIR && timeout 25 $COMPOSE logs --tail=40 --follow postiz" || true

echo
info "${GREEN}Migration deploy complete.${RESET}"
echo
echo "Verify in container env:"
echo "  ssh $SSH_HOST \"docker exec postiz env | grep -E '^(X_API|LINKEDIN_PAGE_CLIENT_ID)=' | sed -E 's/(_KEY|_SECRET|_ID)=.{0,4}.*/\\\\1=<set, masked>/'\""
echo
echo "Then in browser: https://social.itsborderline.com → Launches → Add channel → X → confirm connect flow works"
