
# outputs.tf of nat module
output "nat_interface_id" {
  value = aws_instance.nat.primary_network_interface_id  # returns eni-xxx
}