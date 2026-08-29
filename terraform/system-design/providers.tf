# ---------------------------------------------------------------------------
# THE ONLY LOCAL-SPECIFIC FILE IN THIS STACK. See ../foundation/providers.tf
# for the full rationale. Every other .tf file is valid against real AWS.
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
    ec2                      = var.localstack_endpoint
    elbv2                    = var.localstack_endpoint
    ecs                      = var.localstack_endpoint
    iam                      = var.localstack_endpoint
    sts                      = var.localstack_endpoint
    logs                     = var.localstack_endpoint
    cloudwatch               = var.localstack_endpoint
    applicationautoscaling   = var.localstack_endpoint
    resourcegroupstaggingapi = var.localstack_endpoint
  }
}
