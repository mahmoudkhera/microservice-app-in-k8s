locals {
  default_user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y nginx
    echo "ok" > /var/www/html/healthz
    systemctl enable --now nginx
  EOF

  user_data = var.kubernetes_user_data != "" ? file(var.kubernetes_user_data) : local.default_user_data

  # "web-1" => subnet A, "web-2" => subnet B, "web-3" => subnet A, ...
  instances = {
    for i in range(var.instance_count) :
    "${var.instance_name}-${i + 1}" => {
      subnet_id = var.subnet_ids[i % length(var.subnet_ids)] // round robin
    }
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "this" {
  for_each = local.instances

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = each.value.subnet_id
  key_name                    = var.key_name != "" ? var.key_name : null
  vpc_security_group_ids      = var.security_group_ids
  iam_instance_profile        = var.iam_instance_profile_name != "" ? var.iam_instance_profile_name : null
  associate_public_ip_address = var.associate_public_ip
  user_data                   = local.user_data

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125
    encrypted             = true
    delete_on_termination = true
    tags                  = { Name = "${each.key}-root" }
  }

  tags = {
    Name        = each.key
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_eip" "this" {
  for_each = var.create_eip ? aws_instance.this : {}

  instance = each.value.id
  domain   = "vpc"

  tags = {
    Name      = "${each.key}-eip"
    ManagedBy = "Terraform"
  }
}