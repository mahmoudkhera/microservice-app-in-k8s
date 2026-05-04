variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Environment name (e.g., dev, prod)"
  type        = string
  default     = "dev"
}
variable "name" {
  description = "name of resource in aws"
  type        = string
  default     = "dev"
}
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "192.168.0.0/16"
}

variable "public_subnets" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["192.168.1.0/24", "192.168.2.0/24"]
}



variable "private_subnets"{
  description ="cider blocks for internal load balancer"
  type  =list(string)
  default=["192.168.3.0/24", "192.168.4.0/24"]
}


variable "bastion_subnet" {
  description = "CIDR blocks for public subnets"
  type        = string
  default     = "192.168.5.0/24"
}

variable "allowed_ssh_cidr_blocks" {
  description = "List of CIDR blocks allowed to SSH to bastion host"
  type        = list(string)
  default     = ["192.168.5.0/24"]
} 



variable "availability_zones" {
  description = "Availability zones"
  type        = list(string)
  default     = ["eu-west-1a", "eu-west-1b"]
}



variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.nano"
}

variable "key_name" {
  description = "Name of the SSH key pair"
  type        = string
  default     = "ec2-key"
}



variable "kubernetes_user_data" {
  description = "Path to user data template file"
  type        = string
  default = "./templates/k8s_setup.tpl"
}

variable "kubernetes_data_vars" {
  description = "Variables to pass into user data template"
  type        = map(string)
  default     = {}
}

