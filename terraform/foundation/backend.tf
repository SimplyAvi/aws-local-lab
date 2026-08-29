terraform {
  # Local backend is the committed default: this is a single-user local lab, the
  # state has no secrets worth protecting, and a remote backend (S3 + Dynamo)
  # would itself have to be emulated. `terraform.tfstate` is gitignored.
  # The system-design stack reads this file via `terraform_remote_state`.
  backend "local" {}
}
