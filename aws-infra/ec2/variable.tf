variable "instance_name" {
  type = string
}

variable "instance_count" {
  type    = number
  default = 1
}

variable "instance_type" {
  type = string
}

variable "environment" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "key_name" {
  type    = string
  default = ""
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