output "server_ips" {
  value = {
    for name, mod in module.app_servers :
    name => mod.public_ip
  }
}

output "api_server_ip" {
  value = module.app_servers["api"].public_ip
}

output "payments_server_ip" {
  value = module.app_servers["payments"].public_ip
}

output "logs_server_ip" {
  value = module.app_servers["logs"].public_ip
}