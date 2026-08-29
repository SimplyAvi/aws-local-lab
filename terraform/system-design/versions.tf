terraform {
  # See terraform/README.md. Exact working versions: Terraform v1.5.7,
  # hashicorp/aws v5.83.1.
  required_version = ">= 1.5.0, < 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.83.1"
    }
  }
}
