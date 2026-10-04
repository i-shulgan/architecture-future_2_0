locals {
  # Публичный адрес ВМ с ролью bastion — точка входа для SSH
  bastion_ip = try([for name, vm in yandex_compute_instance.vm : vm.network_interface[0].nat_ip_address if var.vms[name].role == "bastion"][0], null)
}

output "network_id" {
  description = "ID облачной сети"
  value       = yandex_vpc_network.main.id
}

output "subnets" {
  description = "Подсети: ID, зона, CIDR и признак приватности"
  value = {
    for name, s in yandex_vpc_subnet.main : name => {
      id      = s.id
      zone    = s.zone
      cidr    = s.v4_cidr_blocks[0]
      private = var.subnets[name].private
    }
  }
}

output "nat_gateway_id" {
  description = "ID NAT-шлюза для приватных подсетей"
  value       = yandex_vpc_gateway.nat.id
}

output "vms" {
  description = "ВМ: роль, подсеть, внутренний и внешний IP"
  value = {
    for name, vm in yandex_compute_instance.vm : name => {
      role        = var.vms[name].role
      subnet      = var.vms[name].subnet
      internal_ip = vm.network_interface[0].ip_address
      external_ip = vm.network_interface[0].nat_ip_address
    }
  }
}

output "bastion_public_ip" {
  description = "Публичный IP bastion"
  value       = local.bastion_ip
}

output "ssh_commands" {
  description = "Команды для SSH-доступа: на bastion напрямую, на остальные ВМ через bastion"
  value = {
    for name, vm in yandex_compute_instance.vm : name => (
      var.vms[name].public_ip
      ? "ssh ${var.vm_user}@${vm.network_interface[0].nat_ip_address}"
      : local.bastion_ip == null ? null : "ssh -J ${var.vm_user}@${local.bastion_ip} ${var.vm_user}@${vm.network_interface[0].ip_address}"
    )
  }
}

output "nessie_api_urls" {
  description = "Внутренние адреса REST API каталога Nessie"
  value = [
    for name, vm in yandex_compute_instance.vm :
    "http://${vm.network_interface[0].ip_address}:${var.nessie_port}/api/v2" if var.vms[name].role == "nessie"
  ]
}

output "lakehouse_bucket" {
  description = "Бакет Lakehouse в Object Storage"
  value       = yandex_storage_bucket.lakehouse.bucket
}
