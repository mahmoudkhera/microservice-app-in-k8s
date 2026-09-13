data "aws_ami" "fck_nat" {
  count       = local.nat_instance ? 1 : 0
  most_recent = true
  owners      = ["568608671756"] # fck-nat maintainer's public AMIs

  filter {
    name   = "name"
    values = ["fck-nat-al2023-*-arm64-ebs"]
  }
}

resource "aws_security_group" "nat" {
  count  = local.nat_instance ? 1 : 0
  name   = "nat-instance"
  vpc_id = module.vpc.vpc_id

  # Anything inside the VPC may send traffic through the NAT
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "nat" {
  count                       = local.nat_instance ? 1 : 0
  ami                         = data.aws_ami.fck_nat[0].id
  instance_type               = var.nat_instance_type
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.nat[0].id]
  associate_public_ip_address = true

  # Required for any NAT: the instance forwards packets it isn't the destination of.
  source_dest_check = false

  tags = { Name = "nat-instance" }
}

# The VPC module creates one private route table per AZ when its NAT is off.
# Give each a default route via the instance's ENI.
resource "aws_route" "private_via_nat_instance" {
  count = local.nat_instance ? var.az_count : 0

  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat[0].primary_network_interface_id
}