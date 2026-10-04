# Несекретные параметры доменной среды.
# cloud_id и folder_id передаются через YC_CLOUD_ID и YC_FOLDER_ID, токен — через YC_TOKEN.

default_zone = "ru-central1-a"
project      = "future20"
environment  = "dev"

subnets = {
  public = {
    zone    = "ru-central1-a"
    cidr    = "10.10.0.0/24"
    private = false
  }
  platform = {
    zone    = "ru-central1-a"
    cidr    = "10.10.10.0/24"
    private = true
  }
  clinic = {
    zone    = "ru-central1-a"
    cidr    = "10.10.20.0/24"
    private = true
  }
}

# SSH на bastion. Здесь заглушка из документационного диапазона: реальный адрес
# администратора задаётся в локальном admin.auto.tfvars (исключён из Git),
# для продуктива — диапазон корпоративного VPN
admin_cidrs = ["203.0.113.10/32"]

security_groups = {
  bastion = {
    description = "Bastion: SSH только из сетей администраторов"
    ingress = [
      { description = "SSH администраторов", protocol = "TCP", port = 22, from_admin = true },
    ]
  }
  platform = {
    description = "Платформа данных: SSH только с bastion, API каталога для платформы и bastion"
    ingress = [
      { description = "SSH с bastion", protocol = "TCP", port = 22, from_vms = ["bastion"] },
    ]
  }
  clinic = {
    description = "Медицинский контур: соединения с платформой данных запрещены в обе стороны"
    ingress = [
      { description = "SSH с bastion", protocol = "TCP", port = 22, from_vms = ["bastion"] },
      { description = "Трафик внутри медицинского контура", protocol = "ANY", from_subnets = ["clinic"] },
    ]
    egress = [
      { description = "Трафик внутри медицинского контура, включая DNS подсети", protocol = "ANY", to_subnets = ["clinic"] },
      { description = "Обновления ОС и пакетов через NAT-шлюз (HTTP)", protocol = "TCP", port = 80, to_cidrs = ["0.0.0.0/0"] },
      { description = "Обновления ОС и пакетов через NAT-шлюз (HTTPS)", protocol = "TCP", port = 443, to_cidrs = ["0.0.0.0/0"] },
      { description = "Синхронизация времени", protocol = "UDP", port = 123, to_cidrs = ["0.0.0.0/0"] },
    ]
  }
}

# Правило доступа к API Nessie добавляется в группу безопасности ВМ nessie автоматически,
# порт — из nessie_port
nessie_api_sources = {
  from_subnets = ["platform"]
  from_vms     = ["bastion"]
}

ssh_public_key_path = "~/.ssh/id_ed25519.pub"

vms = {
  bastion = {
    subnet         = "public"
    ip_address     = "10.10.0.10" # фиксированный адрес — источник SSH для внутренних ВМ
    security_group = "bastion"
    role           = "bastion"
    cores          = 2
    memory         = 1
    core_fraction  = 20
    boot_disk_size = 10
    boot_disk_type = "network-hdd"
    data_disk_size = 0
    data_disk_type = "network-hdd"
    public_ip      = true
    preemptible    = true
  }
  nessie = {
    subnet         = "platform"
    security_group = "platform"
    role           = "nessie"
    cores          = 2
    memory         = 4
    core_fraction  = 50
    boot_disk_size = 20
    boot_disk_type = "network-hdd"
    data_disk_size = 20
    data_disk_type = "network-ssd"
    public_ip      = false
    preemptible    = true
  }
  clinic-adapter = {
    subnet         = "clinic"
    security_group = "clinic"
    role           = "clinic-adapter"
    cores          = 2
    memory         = 2
    core_fraction  = 20
    boot_disk_size = 15
    boot_disk_type = "network-hdd"
    data_disk_size = 10
    data_disk_type = "network-hdd"
    public_ip      = false
    preemptible    = true
  }
}

lakehouse_bucket_max_size_gb = 10
