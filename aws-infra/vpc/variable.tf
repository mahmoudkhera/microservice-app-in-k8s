variable "region" {
  description = "AWS region. Pick the cheapest one that meets your latency needs; us-east-1 is usually lowest."
  type        = string
  default     = "us-east-1"
}

variable "vpc_name" {
  description = "Name of the EKS cluster."
  type        = string
  default     = "stockwatch"
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
  default     = "gateway"
  validation {
    condition     = contains(["gateway", "instance", "none"], var.nat_mode)
    error_message = "nat_mode must be gateway, instance, or none."
  }
}

variable "nat_instance_type" {
  type    = string
  default = "t4g.nano" # ~$3/mo; use t4g.small+ if you need more throughput
}