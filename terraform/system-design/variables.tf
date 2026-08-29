variable "aws_region" {
  description = "AWS region. Must match the foundation stack."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for resources."
  type        = string
  default     = "lab"
}

variable "foundation_state_path" {
  description = "Path to the foundation stack's local state file."
  type        = string
  default     = "../foundation/terraform.tfstate"
}

variable "container_image" {
  description = "Container image for the ECS task."
  type        = string
  default     = "nginx:1.27-alpine"
}

variable "desired_count" {
  description = "Desired running task count."
  type        = number
  default     = 2
}

variable "min_capacity" {
  description = "Auto Scaling minimum."
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Auto Scaling maximum."
  type        = number
  default     = 6
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    Project = "aws-local-lab"
    Stack   = "system-design"
  }
}
