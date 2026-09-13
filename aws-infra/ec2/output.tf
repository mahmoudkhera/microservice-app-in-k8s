output "private_ips_map" {
  description = "Instance name => private IP"
  value       = { for k, v in aws_instance.this : k => v.private_ip }
}


output "public_ips" {
  description = "Instance name => public IP (EIP if created, otherwise the auto-assigned one, or null)"
  value = {
    for k, v in aws_instance.this :
    k => try(aws_eip.this[k].public_ip, v.public_ip)
  }
}

output "instance_private_ip" {
  value = { for k, v in aws_instance.this : k => v.private_ip }
}
output "instance_ids" {
  value = { for k, v in aws_instance.this : k => v.id }
}

# output "instances" {
#   description = "Instance name => id, private IP, public IP, AZ"
#   value = {
#     for k, v in aws_instance.this : k => {
#       id         = v.id
#       private_ip = v.private_ip
#       public_ip  = try(aws_eip.this[k].public_ip, v.public_ip)
#       az         = v.availability_zone
#     }
#   }
# }