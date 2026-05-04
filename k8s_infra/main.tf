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


# Sends 0.0.0.0/0 → Internet Gateway
# Associate with public subnets



# Security Module
module "security" {
  source = "./modules/security"

  environment             = var.environment
  vpc_id                 = module.vpc.vpc_id
  allowed_ssh_cidr_blocks = var.allowed_ssh_cidr_blocks
  private_subnets=var.private_subnets
}


module "public_instance" {
  source = "./modules/ec2"

  # Identity
  instance_name = "bastion"
  environment   = "dev"


  instance_type = "t2.nano"

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
  kubernetes_user_data=var.kubernetes_user_data

  instance_type = "t2.medium"

  # Networking
  subnet_id           = module.vpc.private_subnet_ids[0]
  security_group_ids  = [module.security.private_sg_id]
  associate_public_ip = false    
  create_eip          = false    
  key_name = var.key_name

}

module "worker_ec2" {
  source = "./modules/ec2"

  # Identity
  instance_name = "worker_node"
  environment   = "dev"
  kubernetes_user_data=var.kubernetes_user_data

  instance_type = "t2.medium"

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
















