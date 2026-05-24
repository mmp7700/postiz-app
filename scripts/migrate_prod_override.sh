#!/usr/bin/env bash
# One-shot Stage-1 migration: pulls the current production override down,
# transforms it to use ${VAR} substitution, and produces:
#   - infra/.live/docker-compose.prod.override.yaml.live   (gitignored, raw)
#   - docker-compose.prod.override.yaml                    (committable, ${VAR})
#   - infra/.live/env-additions                            (gitignored, KEY=value lines)
#
# After this runs, you can:
#   1. Review the new override (committable shape) — `cat docker-compose.prod.override.yaml`
#   2. Review the env additions — `cat infra/.live/env-additions`
#   3. Manually merge env additions into .env.prod (the script will help with dedup)
#   4. Validate locally with `docker compose -f docker-compose.yaml -f docker-compose.prod.override.yaml config`
#   5. Once happy, run scripts/deploy_prod_override.sh push (separate script, not yet written)

set -euo pipefail

SSH_HOST="${POSTIZ_SSH_HOST:-postiz}"
REMOTE_DIR="/opt/postiz"
REMOTE_OVERRIDE="${REMOTE_DIR}/docker-compose.prod.override.yaml"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIVE_DIR="${REPO_ROOT}/infra/.live"
LIVE_OVERRIDE="${LIVE_DIR}/docker-compose.prod.override.yaml.live"
NEW_OVERRIDE="${REPO_ROOT}/docker-compose.prod.override.yaml"
ENV_ADDITIONS="${LIVE_DIR}/env-additions"
TRANSFORMER="${REPO_ROOT}/scripts/migrate_override.py"

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
die() { printf "%s%s%s\n" "$RED" "$*" "$RESET" >&2; exit 1; }
info() { printf "%s%s%s\n" "$BOLD" "$*" "$RESET"; }

[[ -x "$TRANSFORMER" ]] || chmod +x "$TRANSFORMER"
mkdir -p "$LIVE_DIR"

info "1/4  SSH probe to $SSH_HOST..."
ssh -o BatchMode=yes -o ConnectTimeout=8 "$SSH_HOST" true 2>/dev/null \
  || die "Cannot ssh to '$SSH_HOST'."

# Refuse to overwrite an existing committable override unless --force
if [[ -f "$NEW_OVERRIDE" && "${1:-}" != "--force" ]]; then
  die "$NEW_OVERRIDE already exists. Re-run with --force to overwrite (an existing copy will be moved aside)."
fi
if [[ -f "$NEW_OVERRIDE" ]]; then
  mv "$NEW_OVERRIDE" "${NEW_OVERRIDE}.preMigration.bak.$(date +%Y%m%d-%H%M%S)"
  info "  Moved existing override aside."
fi

info "2/4  Pulling live override from droplet..."
rsync -e ssh -avz "$SSH_HOST:$REMOTE_OVERRIDE" "$LIVE_OVERRIDE"

info "3/4  Running transformer..."
python3 "$TRANSFORMER" "$LIVE_OVERRIDE" "$NEW_OVERRIDE" "$ENV_ADDITIONS"

info "4/4  Validating new YAML locally with 'docker compose config'..."
if (cd "$REPO_ROOT" && docker compose -f docker-compose.yaml -f docker-compose.prod.override.yaml --env-file /dev/null config > /dev/null 2>"${LIVE_DIR}/compose-config.err"); then
  info "  ${GREEN}YAML parses cleanly.${RESET}"
else
  printf "  %swarning:%s docker compose config returned an error; tail follows:\n" "$YELLOW" "$RESET"
  tail -15 "${LIVE_DIR}/compose-config.err"
  printf "  (this may be expected if base compose uses values not yet in .env)\n"
fi

echo
info "${GREEN}Done.${RESET} Next steps:"
cat <<EOF
  1. Inspect the new committable override:
       cat $NEW_OVERRIDE | head -60

  2. Inspect the extracted env additions (gitignored, has secrets):
       wc -l $ENV_ADDITIONS
       # Don't paste this anywhere — open in editor instead

  3. Diff existing .env.prod against the additions to spot conflicts:
       comm -12 <(awk -F= '!/^#/ && /=/ {print \$1}' $ENV_ADDITIONS | sort -u) \\
                <(awk -F= '!/^#/ && /=/ {print \$1}' $REPO_ROOT/.env.prod | sort -u)
       # ^ keys present in BOTH files. For each, decide which source wins.

  4. Once .env.prod has every key from env-additions:
       docker compose -f docker-compose.yaml -f docker-compose.prod.override.yaml \\
         --env-file .env.prod config | grep -E '^\\s+[A-Z_].*:' | head -50
       # Sanity check the resolved env block

  5. When you're ready to push: we'll write deploy_prod_override.sh next.
EOF
