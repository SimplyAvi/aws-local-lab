#!/usr/bin/env bash
# Tear down everything deploy.sh created. Safe to run repeatedly; missing
# resources are ignored. `make reset` at the lab level also wipes all of this.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
AWSLOCAL="$REPO_ROOT/bin/awslocal"
STACK_ENV="$HERE/.stack.env"

TABLE="notes"; BUCKET="notes-uploads"; QUEUE="notes-events"
API_LAMBDA="notes-api"; WORKER_LAMBDA="notes-worker"; API_ID=""
# shellcheck source=/dev/null
[ -f "$STACK_ENV" ] && . "$STACK_ENV"

q() { "$@" >/dev/null 2>&1 || true; }
log() { printf '\033[36m==>\033[0m %s\n' "$*"; }

log "event source mappings"
for uuid in $("$AWSLOCAL" lambda list-event-source-mappings \
  --function-name "$WORKER_LAMBDA" --query 'EventSourceMappings[].UUID' \
  --output text 2>/dev/null || true); do
  q "$AWSLOCAL" lambda delete-event-source-mapping --uuid "$uuid"
done

log "lambdas"
q "$AWSLOCAL" lambda delete-function --function-name "$API_LAMBDA"
q "$AWSLOCAL" lambda delete-function --function-name "$WORKER_LAMBDA"

if [ -n "${API_ID:-}" ]; then
  log "rest api $API_ID"
  q "$AWSLOCAL" apigateway delete-rest-api --rest-api-id "$API_ID"
else
  for id in $("$AWSLOCAL" apigateway get-rest-apis \
    --query "items[?name=='notes-api'].id" --output text 2>/dev/null || true); do
    q "$AWSLOCAL" apigateway delete-rest-api --rest-api-id "$id"
  done
fi

log "sqs queue"
QURL="$("$AWSLOCAL" sqs get-queue-url --queue-name "$QUEUE" --query QueueUrl --output text 2>/dev/null || true)"
[ -n "$QURL" ] && q "$AWSLOCAL" sqs delete-queue --queue-url "$QURL"

log "s3 bucket"
q "$AWSLOCAL" s3 rb "s3://$BUCKET" --force

log "dynamodb table"
q "$AWSLOCAL" dynamodb delete-table --table-name "$TABLE"

rm -f "$STACK_ENV"
rm -rf "$HERE/.build"
log "destroyed"
