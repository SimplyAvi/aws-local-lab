# ---------------------------------------------------------------------------
# THE ONLY LOCAL-SPECIFIC FILE IN THIS STACK.
#
# Every other .tf file is byte-for-byte valid against real AWS. This file
# redirects the AWS provider at LocalStack's edge endpoint and supplies the
# dummy-credential / skip-* settings LocalStack needs. Chosen over the `tflocal`
# wrapper because it has zero runtime dependencies (no pip / venv), is fully
# committed and deterministic, works unchanged in CI, and keeps the local
# override in a single reviewable file. See terraform/README.md.
#
# To target real AWS: delete this file (and the matching one in
# ../system-design/), then `terraform init -reconfigure`.
# ---------------------------------------------------------------------------

variable "localstack_endpoint" {
  description = "LocalStack edge endpoint. The only local-specific input."
  type        = string
  default     = "http://127.0.0.1:4566"
}

provider "aws" {
  region     = var.aws_region
  access_key = "test"
  secret_key = "test"

  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2   = var.localstack_endpoint
    elbv2 = var.localstack_endpoint
    ecs   = var.localstack_endpoint
    iam   = var.localstack_endpoint
    sts   = var.localstack_endpoint
  }
}
