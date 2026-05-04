
resource "aws_route_table" "this" {
  vpc_id = var.vpc_id

  tags = merge(
    {
      Name        = var.name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Type        = var.is_public ? "public" : "private"
    }
  )
}

# Routes
#Internet Gateway route (for public subnets)
resource "aws_route" "igw" {
  count                  = var.is_public  ? 1 : 0
  route_table_id         = aws_route_table.this.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = var.igw_id
}

# NAT Gateway route (for private subnets)

resource "aws_route" "nat" {
  count                  = !var.is_public  ? 1 : 0
  route_table_id         = aws_route_table.this.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id            = var.nat_network_interface_id   
}


locals {
  subnet_map = {
    for idx, id in var.subnet_ids :
    "subnet_${idx}" => id
  }
}
# Subnet Associations
resource "aws_route_table_association" "this" {
  for_each       = local.subnet_map
  subnet_id      = each.value
  route_table_id = aws_route_table.this.id
}
