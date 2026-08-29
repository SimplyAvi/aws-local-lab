output "alb_arn" {
  description = "ALB ARN."
  value       = module.service.alb_arn
}

output "alb_dns_name" {
  description = "ALB DNS name (control-plane only in LocalStack - no real dataplane; use lab-integration Layer 3 for real load tests)."
  value       = module.service.alb_dns_name
}

output "target_group_arn" {
  description = "Target group ARN."
  value       = module.service.target_group_arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = module.service.ecs_cluster_name
}

output "ecs_service_name" {
  description = "ECS service name."
  value       = module.service.ecs_service_name
}

output "autoscaling_target_resource_id" {
  description = "Application Auto Scaling resource ID."
  value       = module.service.autoscaling_target_resource_id
}
