#!/usr/bin/env bash
# aws-local-lab :: seed.sh - (re)create a known baseline of lab resources.
#
# The community LocalStack image does not reliably persist data-plane state
# (S3 objects, DynamoDB items) across a restart - durable persistence and
# Cloud Pods are LocalStack Pro features. So the regression baseline for the
# no-token lab is "wipe, then re-seed": deterministic and free.
#
#   make reset NO_TOKEN=1 && make up NO_TOKEN=1 && ./integration/seed.sh
#   (wrapped by `make lab-seed`)
#
# This is an EXAMPLE baseline. Replace the body with your project's fixtures;
# keep every call idempotent so re-running is safe.
set -eu

ENDPOINT="${LAB_ENDPOINT:-http://localhost:4566}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="$REGION"

aws_() { aws --endpoint-url="$ENDPOINT" --region "$REGION" "$@"; }

echo "seeding baseline at $ENDPOINT"

# --- S3 -------------------------------------------------------------------
for bucket in app-assets app-uploads; do
  if aws_ s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    echo "  bucket $bucket exists"
  else
    aws_ s3 mb "s3://$bucket" >/dev/null
    echo "  bucket $bucket created"
  fi
done

# --- DynamoDB -----------------------------------------------------------
if aws_ dynamodb describe-table --table-name app-main >/dev/null 2>&1; then
  echo "  table app-main exists"
else
  aws_ dynamodb create-table \
    --table-name app-main \
    --attribute-definitions AttributeName=pk,AttributeType=S \
    --key-schema AttributeName=pk,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws_ dynamodb wait table-exists --table-name app-main
  echo "  table app-main created"
fi

echo "baseline ready"
