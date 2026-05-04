output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.this.id
}


output "instance_arn" {
  description = "ARN of the EC2 instance"
  value       = aws_instance.this.arn
}


output "private_ip" {
  description = "Private IP address of the instance"
  value       = aws_instance.this.private_ip
}

output "public_ip" {
  description = "Public IP address of the instance (if associated)"
  value       = aws_instance.this.public_ip
}


output "elastic_ip" {
  description = "Elastic IP address (if created)"
  value       = var.create_eip ? aws_eip.this[0].public_ip : null
}

output "instance_state" {
  description = "Current state of the instance"
  value       = aws_instance.this.instance_state
}

output "availability_zone" {
  description = "Availability zone where the instance is launched"
  value       = aws_instance.this.availability_zone
}