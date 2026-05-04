# NAT Instance AMI (using fck-nat - most popular community NAT AMI)
data "aws_ami" "fck_nat" {
  most_recent = true
  owners      = ["568608671756"] # fck-nat official account

  filter {
    name   = "name"
    values = ["fck-nat-al2023-*-arm64-*"]
  }
}


# Elastic IP for NAT Instance
resource "aws_eip" "nat" {
  domain   = "vpc"
  tags = {
    Name        = "${var.environment}-nat-eip"
    Environment = var.environment
  }
}

# NAT Instance (single, in first public subnet)
resource "aws_instance" "nat" {
  ami                         = data.aws_ami.fck_nat.id
  instance_type               = "t4g.nano"   
  subnet_id                   = var.public_subnet_ids[0]
  vpc_security_group_ids      = var.security_group_ids
  source_dest_check           = false        # Required for NAT to work
  associate_public_ip_address = true

  tags = {
    Name        = "${var.environment}-nat"
    Environment = var.environment
  }
}

# Attach EIP to NAT Instance
resource "aws_eip_association" "nat" {
  instance_id   = aws_instance.nat.id
  allocation_id = aws_eip.nat.id
}


