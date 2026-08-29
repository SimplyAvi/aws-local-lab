#!/usr/bin/env bash
# aws-local-lab :: ci/wait-for-health.sh
#
# Bounded wait for the LocalStack edge to come up and for the core community
# services to reach "available" or "running". Used by the CI e2e job to absorb
# cold-start races (image pull + boot) without weakening any test assertion.
#
#   ci/wait-for-health.sh [timeout_seconds]
#
# Env:
#   LAB_ENDPOINT   edge base URL (default http://localhost:4566)
#   CORE_SERVICES  space-separated service names to require
#
# Exit 0 once every CORE_SERVICES entry is available/running; exit 1 on timeout.
set -euo pipefail

LAB_ENDPOINT="${LAB_ENDPOINT:-http://localhost:4566}"
HEALTH_URL="${LAB_ENDPOINT}/_localstack/health"
TIMEOUT="${1:-180}"
CORE_SERVICES="${CORE_SERVICES:-s3 dynamodb lambda sqs apigateway iam sts}"

deadline=$(( $(date +%s) + TIMEOUT ))
attempt=0

while [ "$(date +%s)" -lt "$deadline" ]; do
  attempt=$((attempt + 1))
  body="$(curl -sf --max-time 5 "$HEALTH_URL" 2>/dev/null || true)"

  if [ -n "$body" ]; then
    missing=""
    for svc in $CORE_SERVICES; do
      state="$(printf '%s' "$body" | jq -r --arg s "$svc" '.services[$s] // "absent"')"
      case "$state" in
        available | running) ;;
        *) missing="$missing $svc($state)" ;;
      esac
    done

    if [ -z "$missing" ]; then
      echo "edge healthy after ${attempt} attempt(s); core services ready:"
      printf '%s\n' "$body" | jq -r '.services | to_entries[] | "  \(.key)\t\(.value)"' | sort
      exit 0
    fi
    echo "attempt ${attempt}: waiting on -${missing}"
  else
    echo "attempt ${attempt}: edge not reachable at ${HEALTH_URL}"
  fi

  sleep 3
done

echo "timed out after ${TIMEOUT}s waiting for ${HEALTH_URL}" >&2
curl -s --max-time 5 "$HEALTH_URL" || true
exit 1
