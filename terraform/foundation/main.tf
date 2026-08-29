# Foundation stack: the network baseline every other stack builds on.
# Pure real-AWS Terraform.

module "network" {
  source = "../modules/network"

  name         = var.name
  vpc_cidr     = var.vpc_cidr
  subnet_count = var.subnet_count
  tags         = var.tags
}

# ALB security group: open HTTP from the internet.
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "ALB ingress"
  vpc_id      = module.network.vpc_id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-alb-sg" })
}

# Service security group: accept traffic only from the ALB.
resource "aws_security_group" "service" {
  name        = "${var.name}-service-sg"
  description = "Container service ingress from the ALB"
  vpc_id      = module.network.vpc_id

  ingress {
    description     = "From ALB"
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-service-sg" })
}
