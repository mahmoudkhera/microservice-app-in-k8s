# Security


resource "aws_security_group" "alb" {
    name = "${var.environment}-alb-sg"
    description = "security group for application load balancer"
    vpc_id = var.vpc_id


    ingress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }

      egress { 
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = var.private_subnets
  }
   tags = {
    Name        = "${var.environment}-alb-sg"
    Environment = var.environment
  }

}




resource "aws_security_group" "bastion_sg" {
  vpc_id = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # restrict later
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = var.private_subnets
  }

   tags = {
    Name        = "${var.environment}-bastion-sg"
    Environment = var.environment
  }
}

resource "aws_security_group" "private_sg" {
  name        = "${var.environment}-private-sg"
  description = "Security group for k8s"
  vpc_id      = var.vpc_id

ingress {
  from_port       = 0
  to_port         = 65535
  protocol        = "tcp"
  security_groups = [aws_security_group.alb.id]
}
    ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks =var.private_subnets
  }

  

   ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    cidr_blocks   =var.allowed_ssh_cidr_blocks
  }


  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-private-sg"
    Environment = var.environment
  }
}


resource "aws_security_group" "nat_sg" {
  name        = "${var.environment}-nat-sg"
  description = "Security group for NAT instance"
  vpc_id      = var.vpc_id

  # Allow all outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = concat(var.private_subnets)
  }

  tags = {
    Name        = "${var.environment}-nat-sg"
    Environment = var.environment
  }
}
