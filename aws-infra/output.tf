output "bastion_public_ip" {
  value = values(module.bastion.public_ips)[0]
}
output "alb_dns_name" {
  value = module.alb.alb_dns_name
}


output "master_private_ips" {
  value = module.master.instance_private_ip
}

output "worker_private_ips" {
  value = module.worker.instance_private_ip
}
