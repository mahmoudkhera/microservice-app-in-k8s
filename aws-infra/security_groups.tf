# ALB 
resource "aws_security_group" "alb" {
  name        = "${var.environment}-alb-sg"
  description = "Application load balancer"
  vpc_id      = module.vpc.vpc_id

  tags = { Name = "${var.environment}-alb-sg", Environment = var.environment }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_nodes" {
  security_group_id            = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 30080
  to_port                      = 30443
  referenced_security_group_id = aws_security_group.private_sg.id
}

#Nodes 
resource "aws_security_group" "private_sg" {
  name        = "${var.environment}-private-sg"
  description = "Kubernetes nodes"
  vpc_id      = module.vpc.vpc_id

  tags = { Name = "${var.environment}-private-sg", Environment = var.environment }
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb" {
  security_group_id            = aws_security_group.private_sg.id
  ip_protocol                  = "tcp"
  from_port                    = 30080
  to_port                      = 30443
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_self" {
  security_group_id            = aws_security_group.private_sg.id
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.private_sg.id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_ssh_from_bastion" {
  security_group_id            = aws_security_group.private_sg.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.bastion.id
}

resource "aws_vpc_security_group_egress_rule" "nodes_all" {
  security_group_id = aws_security_group.private_sg.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Bastion 
resource "aws_security_group" "bastion" {
  name        = "${var.environment}-bastion-sg"
  description = "SSH bastion"
  vpc_id      = module.vpc.vpc_id

  tags = { Name = "${var.environment}-bastion-sg", Environment = var.environment }
}

resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  security_group_id = aws_security_group.bastion.id
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "bastion_all" {
  security_group_id = aws_security_group.bastion.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}