variable "name" {
  description = "Name prefix for resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC the target group and service run in."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the ALB and the Fargate tasks (2+ across AZs)."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group for the ALB."
  type        = string
}

variable "service_security_group_id" {
  description = "Security group for the service ENIs."
  type        = string
}

variable "container_name" {
  description = "Container name in the task definition."
  type        = string
  default     = "app"
}

variable "container_image" {
  description = "Container image for the task."
  type        = string
  default     = "nginx:1.27-alpine"
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
  default     = 80
}

variable "task_cpu" {
  description = "Fargate task CPU units."
  type        = string
  default     = "256"
}

variable "task_memory" {
  description = "Fargate task memory (MiB)."
  type        = string
  default     = "512"
}

variable "desired_count" {
  description = "Desired running task count."
  type        = number
  default     = 2
}

variable "min_capacity" {
  description = "Auto Scaling minimum task count."
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Auto Scaling maximum task count."
  type        = number
  default     = 6
}

variable "cpu_target_value" {
  description = "Target average CPU utilization for the scaling policy."
  type        = number
  default     = 50
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
