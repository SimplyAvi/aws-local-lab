terraform {
  # Pinned to the 1.5.x line - last MPL-licensed Terraform, adequate for this
  # local lab and safe to reference from a public repo. Recorded exact working
  # version: Terraform v1.5.7 (see terraform/README.md).
  required_version = ">= 1.5.0, < 1.6.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Recorded exact working version: hashicorp/aws v5.83.1 (pinned in
      # .terraform.lock.hcl). Bump deliberately.
      version = "5.83.1"
    }
  }
}
