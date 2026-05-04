variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
}

variable "public_subnets" {
  description = "List of public subnet CIDR blocks"
  type        = list(string)
}

variable "private_subnets"{
  description ="cider blocks for internal load balancer"
  type  =list(string)
  
}

variable "bastion_subnet" {
  description = "CIDR blocks for public subnets"
  type        = string
  default     = "192.168.5.0/24"
}



variable "availability_zones" {
  description = "Availability zones"
  type        = list(string)
  default     = ["eu-west-1a", "eu-west-1b"]
}
