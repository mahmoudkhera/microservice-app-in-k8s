

module "vpc" {
  source = "./vpc"
  vpc_name = var.vpc_name
  environment = var.environment
  vpc_cidr = var.vpc_cidr
  az_count = var.az_count
  enable_nat_gateway = var.enable_nat_gateway
  single_nat_gateway = var.single_nat_gateway
  public_access_cidrs = var.public_access_cidrs
  nat_mode=var.nat_mode
  nat_instance_type = var.nat_instance_type

}


module "alb" {
  source = "./alb"
  vpc_id=module.vpc.vpc_id
  environment = var.environment
  public_subnets=module.vpc.public_subnets
  target_instance_ids = merge(module.master.instance_ids, module.worker.instance_ids)
  security_group_ids= [aws_security_group.alb.id]
  target_port =30080

}

 resource "aws_key_pair" "this" {
  key_name   = var.key_name
  public_key = file("~/.ssh/ec2-key.pub")   
}
module "master" {
  source = "./ec2"

  instance_name  = "${var.name}-master"
  instance_count = 1
  instance_type  = var.instance_type
  environment    = var.environment

  # Spread across the private subnets; instances are reached through the ALB
  subnet_ids = module.vpc.private_subnets

  # The app SG from security_groups.tf - allows app_port from the ALB and SSH from ssh_allowed_cidrs
  security_group_ids = [aws_security_group.private_sg.id]
  kubernetes_user_data =  "${path.root}/template/k8s-master.sh"
  key_name                  = var.key_name
  iam_instance_profile_name = aws_iam_instance_profile.ec2_k8s.name
}
module "worker" {
  source = "./ec2"

  instance_name  = "${var.name}-worker"
  instance_count = 1
  instance_type  = var.instance_type
  environment    = var.environment

  # Spread across the private subnets; instances are reached through the ALB
  subnet_ids = module.vpc.private_subnets
  kubernetes_user_data =  "${path.root}/template/k8s-node.sh"
  # The app SG from security_groups.tf - allows app_port from the ALB and SSH from ssh_allowed_cidrs
  security_group_ids = [aws_security_group.private_sg.id]

  key_name                  = var.key_name
  iam_instance_profile_name = aws_iam_instance_profile.ec2_k8s.name
}
module "bastion" {
  source = "./ec2"

  instance_name       = "${var.name}-bastion"
  instance_count      = 1
  instance_type       = "t3.micro"
  environment         = var.environment
  subnet_ids          = [module.vpc.public_subnets[0]]   # one public subnet
  security_group_ids  = [aws_security_group.bastion.id]
  key_name            = var.key_name
  associate_public_ip = true
  create_eip          = true     # stable IP so your ~/.ssh/config doesn't change
  root_volume_size    = 8
}

