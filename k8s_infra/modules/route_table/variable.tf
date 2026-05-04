

variable "name" {
  description = "Name tag for the route table"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "vpc_id" {
  description = "VPC ID where the route table will be created"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs to associate with this route table"
  type        = list(string)
  default     = []
}


variable "is_public" {
  description = "Set to true for public subnets (uses IGW), false for private (uses NAT)"
  type        = bool
  default     = false
}


variable "igw_id" {
  description = "Internet Gateway ID — required when is_public = true"
  type        = string
  default     = ""
}

variable "nat_network_interface_id" {
  description = "NAT Instance ENI ID (use this instead of nat_gateway_id for NAT instances)"
  type        = string
  default     = ""
}




