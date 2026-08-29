output "vpc_id" {
  description = "VPC ID."
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = module.network.vpc_cidr
}

output "public_subnet_ids" {
  description = "Public subnet IDs across AZs."
  value       = module.network.public_subnet_ids
}

output "availability_zones" {
  description = "AZs the subnets landed in."
  value       = module.network.availability_zones
}

output "alb_security_group_id" {
  description = "Security group ID for the ALB."
  value       = aws_security_group.alb.id
}

output "service_security_group_id" {
  description = "Security group ID for the container service."
  value       = aws_security_group.service.id
}
