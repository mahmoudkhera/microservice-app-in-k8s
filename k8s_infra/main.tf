terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = var.aws_region
}



# VPC Module
module "vpc" {
  source = "./modules/vpc"

  environment     = var.environment
  vpc_cidr       = var.vpc_cidr
  public_subnets  = var.public_subnets

  private_subnets = var.private_subnets

  availability_zones  = var.availability_zones
}





# Security Module
module "security" {
  source = "./modules/security"

  environment             = var.environment
  vpc_id                 = module.vpc.vpc_id
  allowed_ssh_cidr_blocks = var.allowed_ssh_cidr_blocks
  private_subnets=var.private_subnets
}


resource "aws_ssm_parameter" "k8s_join_command" {
  name  = "/k8s/join-command"
  type  = "String"
  value = "placeholder"   # master will overwrite this at boot

  lifecycle {
    ignore_changes = [value] 
  }
}

locals {
  secret_content = file("${path.module}/sealed-secrets-key.yaml")
}

resource "aws_secretsmanager_secret" "yaml_secret" {
  name                    = "my-yaml-secret"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "yaml_secret_version" {
  secret_id     = aws_secretsmanager_secret.yaml_secret.id
  secret_string = local.secret_content
}
resource "aws_iam_policy" "secret_access" {
  name = "secret-access-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = aws_secretsmanager_secret.yaml_secret.arn
      }
    ]
  })
}


#  IAM Role for EC2 instances
resource "aws_iam_role" "ec2_k8s_role" {
  name = "ec2-k8s-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}





resource "aws_iam_role_policy_attachment" "ssm_access" {
  role       = aws_iam_role.ec2_k8s_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMFullAccess"
}

resource "aws_iam_role_policy_attachment" "secret_access" {
  role       = aws_iam_role.ec2_k8s_role.name 
  policy_arn = aws_iam_policy.secret_access.arn
}

resource "aws_iam_instance_profile" "ec2_k8s_profile" {
  name = "ec2-k8s-profile"
  role = aws_iam_role.ec2_k8s_role.name
}



module "public_instance" {
  source = "./modules/ec2"

  # Identity
  instance_name = "bastion"
  environment   = "dev"


  instance_type = "t2.nano"
    private_ip ="192.168.5.7"   


  # Networking
  subnet_id           = module.vpc.bastion_subnet_id
  security_group_ids  = [module.security.bastion_sg_id]
  associate_public_ip = true     # set false for private subnets
  create_eip          = false    
  key_name = var.key_name

}


module "master_ec2" {
  source = "./modules/ec2"

  # Identity
  instance_name = "master_node"
  environment   = "dev"
  kubernetes_user_data=var.kubernetes_master_user_data

  instance_type = "t2.medium"

  # Networking
  subnet_id           = module.vpc.private_subnet_ids[0]
  security_group_ids  = [module.security.private_sg_id]
  associate_public_ip = false 
  private_ip ="192.168.3.7"   
  iam_instance_profile_name = aws_iam_instance_profile.ec2_k8s_profile.name
  create_eip          = false    
  key_name = var.key_name

}

module "worker_ec2" {
  source = "./modules/ec2"

  # Identity
  instance_name = "worker_node"
  environment   = "dev"
  kubernetes_user_data=var.kubernetes_node_user_data

  instance_type = "t2.medium"
  private_ip ="192.168.3.8"   
  iam_instance_profile_name = aws_iam_instance_profile.ec2_k8s_profile.name


  # Networking
  subnet_id           = module.vpc.private_subnet_ids[0]
  security_group_ids  = [module.security.private_sg_id]
  associate_public_ip = false    
  create_eip          = false    
  key_name = var.key_name

}

module "nat_instance" {
  source="./modules/nat_instance"
    vpc_id = module.vpc.vpc_id

  environment   = var.environment

  public_subnet_ids       = module.vpc.public_subnet_ids
  security_group_ids  = [module.security.nat_sg_id]


}

module "public_route_table" {
  source = "./modules/route_table"

  name        = "my-vpc-public-rt"
  environment = "dev"
  vpc_id      = module.vpc.vpc_id
  is_public  = true
  igw_id     = module.vpc.igw_id

  subnet_ids = concat([module.vpc.bastion_subnet_id], module.vpc.public_subnet_ids)

}

module "private_route_table" {
  source = "./modules/route_table"

  name        = "my-vpc-private-rt"
  environment = "dev"
  vpc_id      = module.vpc.vpc_id

  is_public      = false
  nat_network_interface_id    = module.nat_instance.nat_interface_id

  subnet_ids = module.vpc.private_subnet_ids

}


# Application Load Balancer Module
module "alb" {
  source = "./modules/alb"

  environment     = var.environment
  security_group_ids= [module.security.alb_security_group_id]
  vpc_id         = module.vpc.vpc_id
  public_subnets = module.vpc.public_subnet_ids
}
















