output "route_table_id" {
  description = "ID of the created route table"
  value       = aws_route_table.this.id
}

output "route_table_arn" {
  description = "ARN of the created route table"
  value       = aws_route_table.this.arn
}

output "associated_subnet_ids" {
  description = "List of subnet IDs associated with this route table"
  value       = var.subnet_ids
}