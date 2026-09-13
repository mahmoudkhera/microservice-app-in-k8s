output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "public_subnets" {
  description = "Public subnet IDs."
  value       = module.vpc.public_subnets
}

output "private_subnets" {
  description = "Private subnet IDs."
  value       = module.vpc.private_subnets
}

# Handy if the caller needs to know where nodes/instances should go
output "nat_subnet_ids" {
  description = "Private subnets when NAT is enabled, public subnets otherwise."
  value       = local.nat_subnet_ids
}


output "private_subnet_cidrs" {
  value = module.vpc.private_subnets_cidr_blocks
}
output "public_subnets_cidr_blocks" {
  description = "Public subnet CIDRs, same order as public_subnets."
  value       = module.vpc.public_subnets_cidr_blocks
}