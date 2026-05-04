
output "alb_security_group_id" {
  description = "ID of the ALB security group"
  value       = aws_security_group.alb.id
}




output "bastion_sg_id" {
  description = "ID of bastion security group"
  value       = aws_security_group.bastion_sg.id
}




output "private_sg_id" {
  description = "ID of private security group"
  value       = aws_security_group.private_sg.id
}

output "nat_sg_id" {
  description = "ID of private security group"
  value       = aws_security_group.nat_sg.id
}