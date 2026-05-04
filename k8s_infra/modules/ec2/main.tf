locals {
  user_data = var.kubernetes_user_data != "" ? file(var.kubernetes_user_data) : null
}
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical's official AWS account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
resource "aws_instance" "this" {
  ami                         =  data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  key_name                    = var.key_name != "" ? var.key_name : null
  vpc_security_group_ids      = var.security_group_ids
  iam_instance_profile        = var.iam_instance_profile != "" ? var.iam_instance_profile : null
  associate_public_ip_address = var.associate_public_ip
  user_data                   =  local.user_data




  tags = merge(
    {
      Name        = var.instance_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  )

  lifecycle {
    ignore_changes = [ami]
  }
}


resource "aws_eip" "this" {
  count    = var.create_eip ? 1 : 0
  instance = aws_instance.this.id
  domain   = "vpc"

  tags = {
    Name      = "${var.instance_name}-eip"
    ManagedBy = "Terraform"
  }
}
