#!/usr/bin/env bash
# aws-local-lab :: health-check - query the LocalStack edge and print a
# service -> state table. Run by `make status`.
#
# Health-endpoint contract (see docs/foundation.md):
#   GET http://localhost:4566/_localstack/health
#   -> {"services": {"s3": "available", "lambda": "running", ...}, "edition": "..."}
#   states: available (loadable, not yet started) | running (started) |
#           disabled | error
#
# Exit codes: 0 = edge reachable, 1 = edge unreachable.
set -euo pipefail

LAB_ENDPOINT="${LAB_ENDPOINT:-http://localhost:4566}"
HEALTH_URL="${LAB_ENDPOINT}/_localstack/health"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_DIM=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_BOLD=''
fi

body="$(curl -sf --max-time 5 "$HEALTH_URL" 2>/dev/null)" || {
  printf '%sedge unreachable at %s%s\n' "$C_RED" "$HEALTH_URL" "$C_RESET" >&2
  printf 'is the lab up? try: make up\n' >&2
  exit 1
}

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "$body"
  printf '%s(install jq for a formatted table)%s\n' "$C_DIM" "$C_RESET" >&2
  exit 0
fi

edition="$(printf '%s' "$body" | jq -r '.edition // "unknown"')"
version="$(printf '%s' "$body" | jq -r '.version // "unknown"')"
printf '%sLocalStack%s  edition=%s  version=%s  %s%s%s\n\n' \
  "$C_BOLD" "$C_RESET" "$edition" "$version" "$C_DIM" "$HEALTH_URL" "$C_RESET"

printf '%s%-28s %s%s\n' "$C_BOLD" "SERVICE" "STATE" "$C_RESET"
printf '%s' "$body" | jq -r '.services | to_entries[] | "\(.key)\t\(.value)"' \
  | sort | while IFS=$'\t' read -r svc state; do
  case "$state" in
    running)   color="$C_GREEN" ;;
    available) color="$C_DIM" ;;
    disabled)  color="$C_YELLOW" ;;
    *)         color="$C_RED" ;;
  esac
  printf '%-28s %s%s%s\n' "$svc" "$color" "$state" "$C_RESET"
done

running_count="$(printf '%s' "$body" | jq -r '[.services[] | select(. == "running")] | length')"
avail_count="$(printf '%s' "$body" | jq -r '[.services[] | select(. == "available")] | length')"
printf '\n%s%s running, %s available%s\n' "$C_DIM" "$running_count" "$avail_count" "$C_RESET"
