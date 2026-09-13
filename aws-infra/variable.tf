variable "region" {
  description = "AWS region. Pick the cheapest one that meets your latency needs; us-east-1 is usually lowest."
  type        = string
  default     = "eu-west-1"
}


#    VPC 

variable "name" {
  description = "Name project."
  type        = string
  default     = "dev"
}


variable "vpc_name" {
  description = "Name of the vpc."
  type        = string
  default     = "dev"
}

variable "environment" {
  description = "Environment tag."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of AZs. EKS requires a minimum of 2 for the control plane ENIs."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "EKS requires subnets in at least 2 availability zones."
  }
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Set false (default) to run worker nodes in PUBLIC subnets with no NAT Gateway.
    This is the single biggest cost saving in this config: a NAT Gateway is
    ~$33/month in hourly charges PLUS ~$0.045 per GB processed, and every image
    pull goes through it.

    Set true for a private-subnet layout when you need nodes to have no inbound
    reachability from the internet (production, compliance).
  EOT
  type        = bool
  default     = false
}

variable "single_nat_gateway" {
  description = "If NAT is enabled, share ONE gateway across all AZs instead of one per AZ. Saves ~$33/mo per extra AZ; costs you AZ-failure isolation."
  type        = bool
  default     = true
}



variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API endpoint. TIGHTEN THIS to your office/VPN IP - the default is open to the internet."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "nat_mode" {
  description = "gateway = managed NAT Gateway, instance = fck-nat EC2 instance, none = nodes in public subnets"
  type        = string
  default     = "instance"
  validation {
    condition     = contains(["gateway", "instance", "none"], var.nat_mode)
    error_message = "nat_mode must be gateway, instance, or none."
  }
}

variable "nat_instance_type" {
  type    = string
  default = "t4g.nano" #  use t4g.small+ if you need more throughput
}




# ec2 
variable "instance_name" {
  type = string
  default = "t4g.small"
}

variable "instance_count" {
  type    = number
  default = 1
}
variable "instance_type" {
  type = string
  default = "t3.medium"
}
variable "key_name" {
  type    = string
  default = "ec2s-key"
}
variable "iam_instance_profile_name" {
  type    = string
  default = ""
}
variable "associate_public_ip" {
  type    = bool
  default = false
}
variable "create_eip" {
  type    = bool
  default = false
}
variable "kubernetes_user_data" {
  type    = string
  default = ""
}
variable "root_volume_size" {
  type    = number
  default = 30
}
#SG
variable "app_port" {
  description = "Port the application listens on"
  type        = number
  default     = 80
}
variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to SSH to the instances. Empty list = no SSH rule."
  type        = list(string)
  default     = []
}


# k8s iam 
 variable "sealed_secrets_key" {
  description = "Contents of sealed-secrets-key.yaml"
  type        = string
  sensitive   = true
}