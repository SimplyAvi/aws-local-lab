output "vpc_id" {
  description = "ID of the created VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, ordered by AZ index."
  value       = aws_subnet.public[*].id
}

output "availability_zones" {
  description = "AZs the subnets landed in."
  value       = aws_subnet.public[*].availability_zone
}

output "internet_gateway_id" {
  description = "ID of the internet gateway."
  value       = aws_internet_gateway.this.id
}

output "route_table_id" {
  description = "ID of the public route table."
  value       = aws_route_table.public.id
}
