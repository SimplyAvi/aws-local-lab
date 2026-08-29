variable "name" {
  description = "Name prefix for tagged resources."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_count" {
  description = "Number of public subnets to create (spread across AZs, min 2)."
  type        = number
  default     = 2

  validation {
    condition     = var.subnet_count >= 2
    error_message = "subnet_count must be at least 2 for a multi-AZ baseline."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
