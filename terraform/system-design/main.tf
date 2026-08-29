# System-design reference stack: ALB + listener + target group, ECS cluster +
# Fargate service + task definition, and an Auto Scaling target + policy.
#
# Depends on the foundation stack's outputs, read here via terraform_remote_state
# against its local state file (documented seam - see terraform/README.md).
# Pure real-AWS Terraform; the local override lives only in providers.tf.

data "terraform_remote_state" "foundation" {
  backend = "local"

  config = {
    path = var.foundation_state_path
  }
}

module "service" {
  source = "../modules/ecs-service"

  name   = var.name
  vpc_id = data.terraform_remote_state.foundation.outputs.vpc_id

  subnet_ids                = data.terraform_remote_state.foundation.outputs.public_subnet_ids
  alb_security_group_id     = data.terraform_remote_state.foundation.outputs.alb_security_group_id
  service_security_group_id = data.terraform_remote_state.foundation.outputs.service_security_group_id

  container_image = var.container_image
  desired_count   = var.desired_count
  min_capacity    = var.min_capacity
  max_capacity    = var.max_capacity

  tags = var.tags
}
