variable "environment" {
  description = "Environment name"
  type        = string
}

variable vpc_id {
  type        = string
  description = "the vpc that has nat instance "
  
}

variable "public_subnet_ids" {
  description = "CIDR blocks for nat subnets"
  type        = list(string)
  default     = ["192.168.1.0/24"]
}

variable "security_group_ids" {
  description = "List of security group IDs"
  type        = list(string)
}


