variable "instance_name" {
  description = "Name tag for the EC2 instance"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"
}



variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "subnet_id" {
  description = "Subnet ID where the instance will be launched"
  type        = string
}

variable "security_group_ids" {
  description = "List of security group IDs to attach to the instance"
  type        = list(string)
  default     = []
}

variable "key_name" {
  description = "Name of the EC2 key pair for SSH access (leave empty for no key)"
  type        = string
  default     = ""
}



variable "associate_public_ip" {
  description = "Whether to associate a public IP address"
  type        = bool
  default     = false
}



variable "create_eip" {
  description = "Whether to create and attach an Elastic IP"
  type        = bool
  default     = false
}


variable "kubernetes_user_data" {
  description = "Path to user data template file"
  type        = string
  default = ""
}

variable "kubernetes_data_vars" {
  description = "Variables to pass into user data template"
  type        = map(string)
  default     = {}
}


variable "private_ip" {
  description = "Private IP for EC2 instance"
  type        = string
}

variable "iam_instance_profile_name" {
  description = "IAM Instance Profile name for EC2"
  type        = string
  default=""
}
