variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnets" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "target_instance_ids" {
  description = "Map of instance name => instance ID to register in the target group"
  type        = map(string)
  default     = {}
}

variable "target_port" {
  description = "Port the instances listen on (NodePort for k8s)"
  type        = number
  default     = 30080
}

variable "health_check_path" {
  type    = string
  default = "/healthz"
}