output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.idp_vpc.id
}

output "vpc_cidr_block" {
  description = "The CIDR block of the VPC"
  value       = aws_vpc.idp_vpc.cidr_block
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = [aws_subnet.idp_private_subnet_1a.id, aws_subnet.idp_private_subnet_1b.id]
}
