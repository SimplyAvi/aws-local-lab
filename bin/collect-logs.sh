#!/usr/bin/env bash
# aws-local-lab :: collect-logs - build the "attach this when you ask for help"
# diagnostics bundle.
#
# Run by `make logs-bundle`. Produces ./diagnostics/lab-diag-<ts>.tar.gz
# (the diagnostics/ dir is gitignored). Never includes real secrets - token and
# secret-looking env values in `docker inspect` output are redacted to ***.
#
#   bin/collect-logs.sh            write the tarball, print path + summary
#
# Deps: docker, curl, jq, tar, coreutils. No other runtime dependencies.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

EDGE_PORT="${EDGE_PORT:-4566}"
LAB_ENDPOINT="${LAB_ENDPOINT:-http://localhost:${EDGE_PORT}}"
CONTAINER="aws-local-lab"
LOG_MAX_LINES="${LOG_MAX_LINES:-2000}"

COMPOSE=(docker compose -f docker-compose.yml)
[ "${NO_TOKEN:-}" = "1" ] && COMPOSE+=(-f docker-compose.no-token.yml)

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="diagnostics"
WORK="$(mktemp -d)"
BUNDLE_DIR="${WORK}/lab-diag-${TS}"
mkdir -p "$BUNDLE_DIR"
trap 'rm -rf "$WORK"' EXIT

# Redact anything that looks like a credential from a text stream.
redact() {
  sed -E \
    -e 's/("?(LOCALSTACK_AUTH_TOKEN|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|.*_TOKEN|.*_SECRET|.*_PASSWORD|.*APIKEY|.*API_KEY)"?[=:] ?"?)[^"[:space:],]+/\1***/gI' \
    -e 's/(ghp_|github_pat_)[A-Za-z0-9_]+/\1***/g'
}

say() { printf '  - %s\n' "$1"; }

echo "collecting diagnostics into ${OUT_DIR}/lab-diag-${TS}.tar.gz ..."

# 1. diagnose.sh --json (the structured verdict)
"$SCRIPT_DIR/diagnose.sh" --json > "${BUNDLE_DIR}/diagnose.json" 2>"${BUNDLE_DIR}/diagnose.stderr" || true

# 2. diagnose.sh human report (easy to eyeball)
NO_COLOR=1 "$SCRIPT_DIR/diagnose.sh" > "${BUNDLE_DIR}/diagnose.txt" 2>&1 || true

# 3. compose ps + config (resolved) + logs
"${COMPOSE[@]}" ps > "${BUNDLE_DIR}/compose-ps.txt" 2>&1 || true
"${COMPOSE[@]}" config 2>&1 | redact > "${BUNDLE_DIR}/compose-config.yml" || true
"${COMPOSE[@]}" logs --no-color --tail "$LOG_MAX_LINES" 2>&1 | redact > "${BUNDLE_DIR}/compose-logs.txt" || true

# 4. LocalStack edge health
curl -sf --max-time 5 "${LAB_ENDPOINT}/_localstack/health" 2>/dev/null \
  | jq . > "${BUNDLE_DIR}/localstack-health.json" 2>/dev/null \
  || echo '{"error":"edge unreachable"}' > "${BUNDLE_DIR}/localstack-health.json"

# 5. docker inspect of the container (redacted)
docker inspect "$CONTAINER" 2>/dev/null | redact > "${BUNDLE_DIR}/container-inspect.json" \
  || echo '[]' > "${BUNDLE_DIR}/container-inspect.json"

# 6. docker + compose versions, host resources
{
  echo "=== docker version ==="
  docker version 2>&1
  echo
  echo "=== docker compose version ==="
  docker compose version 2>&1
  echo
  echo "=== docker system info ==="
  docker system info 2>&1
} | redact > "${BUNDLE_DIR}/docker-version.txt"

# 7. git SHA / branch / dirty state
{
  echo "sha:    $(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  echo "describe: $(git describe --always --dirty --tags 2>/dev/null || echo unknown)"
  echo
  git status --porcelain=v1 2>/dev/null || true
} > "${BUNDLE_DIR}/git.txt"

# 8. .env KEYS ONLY (never values)
if [ -f .env ]; then
  grep -oE '^[A-Z_][A-Z0-9_]*=' .env | tr -d '=' | sort > "${BUNDLE_DIR}/env-keys.txt"
else
  echo "(no .env file)" > "${BUNDLE_DIR}/env-keys.txt"
fi

# Final secret sweep: fail loudly if a known token pattern slipped through.
if grep -rIlE 'ghp_[A-Za-z0-9]{20,}|LOCALSTACK_AUTH_TOKEN=[A-Za-z0-9]{8,}' "$BUNDLE_DIR" >/dev/null 2>&1; then
  echo "ERROR: a secret pattern survived redaction - aborting, bundle NOT written" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
TARBALL="${OUT_DIR}/lab-diag-${TS}.tar.gz"
tar -czf "$TARBALL" -C "$WORK" "lab-diag-${TS}"

SIZE="$(du -h "$TARBALL" | cut -f1)"
OVERALL="$(jq -r '.overall // "unknown"' "${BUNDLE_DIR}/diagnose.json" 2>/dev/null || echo unknown)"

echo
echo "wrote ${TARBALL} (${SIZE})"
echo "contents:"
say "diagnose.json / diagnose.txt  - full doctor report (overall: ${OVERALL})"
say "compose-ps.txt / compose-config.yml / compose-logs.txt (last ${LOG_MAX_LINES} lines, redacted)"
say "localstack-health.json  - /_localstack/health snapshot"
say "container-inspect.json  - docker inspect of ${CONTAINER} (tokens/secrets redacted)"
say "docker-version.txt  - docker + compose versions, docker system info"
say "git.txt  - repo SHA / branch / working-tree state"
say "env-keys.txt  - .env key names only (no values)"
echo
echo "Secrets are redacted. Attach this tarball when you ask for help."
