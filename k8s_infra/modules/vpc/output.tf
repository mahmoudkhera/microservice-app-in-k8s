output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_name" {
  description = "Name of the VPC"
  value       = aws_vpc.main.tags["Name"]
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = aws_subnet.public[*].id
}


output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = aws_subnet.private_subnets[*].id
}


output "bastion_subnet_id" {
  description = "subnet  ID of bastion"
  value       = aws_subnet.bastion_subnet.id
}


output "igw_id" {
  description = "internet Gateway id"
  value       = aws_internet_gateway.main.id
}








