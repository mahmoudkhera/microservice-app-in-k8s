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
  iam_instance_profile        = var.iam_instance_profile_name != "" ? var.iam_instance_profile_name : null
  associate_public_ip_address = var.associate_public_ip
  private_ip    = var.private_ip
  user_data                   =  local.user_data


   root_block_device {
    volume_size           = 30       # GB
    volume_type           = "gp3"     # gp2, gp3, io1, io2, st1, sc1
    iops                  = 3000      # for gp3/io1/io2
    throughput            = 125       # MB/s, gp3 only
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name = "root-volume"
    }
  }

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
