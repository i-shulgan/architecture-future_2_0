terraform {
  required_version = ">= 1.9.0"

  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.235"
    }
  }
}

# Аутентификация — через переменную окружения YC_TOKEN (IAM- или OAuth-токен)
# или YC_SERVICE_ACCOUNT_KEY_FILE. Секреты в конфигурацию не попадают.
provider "yandex" {
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  zone      = var.default_zone
}

data "yandex_client_config" "current" {}

data "yandex_compute_image" "os" {
  family = var.image_family
}

locals {
  folder_id   = coalesce(var.folder_id, data.yandex_client_config.current.folder_id)
  name_prefix = "${var.project}-${var.environment}"

  common_labels = {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
  }

  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  # ВМ, которым нужен отдельный диск данных
  vms_with_data_disk = { for name, vm in var.vms : name => vm if vm.data_disk_size > 0 }

  # Группы безопасности ВМ каталога Nessie получают правило доступа к API автоматически:
  # порт задаётся один раз в var.nessie_port
  nessie_security_groups = toset([for vm in values(var.vms) : vm.security_group if vm.role == "nessie"])

  nessie_api_rule = {
    description  = "REST API Nessie"
    protocol     = "TCP"
    port         = var.nessie_port
    from_subnets = var.nessie_api_sources.from_subnets
    from_vms     = var.nessie_api_sources.from_vms
    from_admin   = false
  }
}

# ---------------------------------------------------------------------------
# Сеть
# ---------------------------------------------------------------------------

resource "yandex_vpc_network" "main" {
  name        = "${local.name_prefix}-net"
  description = "Сеть доменной среды «Будущее 2.0»"
  labels      = local.common_labels
}

# NAT-шлюз: исходящий интернет для ВМ без публичных адресов
resource "yandex_vpc_gateway" "nat" {
  name   = "${local.name_prefix}-nat"
  labels = local.common_labels

  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "private" {
  name       = "${local.name_prefix}-private-rt"
  network_id = yandex_vpc_network.main.id
  labels     = local.common_labels

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat.id
  }
}

resource "yandex_vpc_subnet" "main" {
  for_each = var.subnets

  name           = "${local.name_prefix}-${each.key}"
  zone           = each.value.zone
  network_id     = yandex_vpc_network.main.id
  v4_cidr_blocks = [each.value.cidr]
  route_table_id = each.value.private ? yandex_vpc_route_table.private.id : null
  labels         = merge(local.common_labels, { zone_role = each.key })
}

# ---------------------------------------------------------------------------
# Группы безопасности
# ---------------------------------------------------------------------------

# Правила задаются в terraform.tfvars. Источник входящего трафика — подсети среды
# (from_subnets), ВМ с фиксированным внутренним адресом (from_vms) и/или сети
# администраторов (from_admin). Назначение исходящего —
# подсети среды (to_subnets) и/или адреса (to_cidrs); если egress не задан,
# исходящий трафик разрешён весь. У приватных подсетей он идёт через NAT-шлюз.
resource "yandex_vpc_security_group" "main" {
  for_each = var.security_groups

  name        = "${local.name_prefix}-${each.key}-sg"
  description = each.value.description
  network_id  = yandex_vpc_network.main.id
  labels      = local.common_labels

  dynamic "ingress" {
    for_each = concat(each.value.ingress, contains(local.nessie_security_groups, each.key) ? [local.nessie_api_rule] : [])
    content {
      description = ingress.value.description
      protocol    = ingress.value.protocol
      port        = ingress.value.port
      v4_cidr_blocks = concat(
        [for subnet in ingress.value.from_subnets : var.subnets[subnet].cidr],
        [for vm in ingress.value.from_vms : "${var.vms[vm].ip_address}/32"],
        ingress.value.from_admin ? var.admin_cidrs : []
      )
    }
  }

  lifecycle {
    precondition {
      condition = alltrue(flatten([
        for rule in each.value.ingress : [for vm in rule.from_vms : contains(keys(var.vms), vm) && try(var.vms[vm].ip_address != null, false)]
      ]))
      error_message = "from_vms в правилах групп безопасности должны ссылаться на ВМ из переменной vms с заданным ip_address."
    }
  }

  dynamic "egress" {
    for_each = each.value.egress
    content {
      description = egress.value.description
      protocol    = egress.value.protocol
      port        = egress.value.port
      v4_cidr_blocks = concat(
        [for subnet in egress.value.to_subnets : var.subnets[subnet].cidr],
        egress.value.to_cidrs
      )
    }
  }
}

# ---------------------------------------------------------------------------
# Диски и виртуальные машины
# ---------------------------------------------------------------------------

resource "yandex_compute_disk" "data" {
  for_each = local.vms_with_data_disk

  name   = "${local.name_prefix}-${each.key}-data"
  zone   = var.subnets[each.value.subnet].zone
  type   = each.value.data_disk_type
  size   = each.value.data_disk_size
  labels = merge(local.common_labels, { role = each.value.role })
}

resource "yandex_compute_instance" "vm" {
  for_each = var.vms

  name        = "${local.name_prefix}-${each.key}"
  hostname    = "${local.name_prefix}-${each.key}"
  zone        = var.subnets[each.value.subnet].zone
  platform_id = var.platform_id
  labels      = merge(local.common_labels, { role = each.value.role })

  allow_stopping_for_update = true

  resources {
    cores         = each.value.cores
    memory        = each.value.memory
    core_fraction = each.value.core_fraction
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.os.id
      size     = each.value.boot_disk_size
      type     = each.value.boot_disk_type
    }
  }

  dynamic "secondary_disk" {
    for_each = each.value.data_disk_size > 0 ? [yandex_compute_disk.data[each.key].id] : []
    content {
      disk_id     = secondary_disk.value
      device_name = "data"
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.main[each.value.subnet].id
    ip_address         = each.value.ip_address
    nat                = each.value.public_ip
    security_group_ids = [yandex_vpc_security_group.main[each.value.security_group].id]
  }

  scheduling_policy {
    preemptible = each.value.preemptible
  }

  metadata = {
    user-data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      user           = var.vm_user
      ssh_public_key = local.ssh_public_key
      role           = each.value.role
      has_data_disk  = each.value.data_disk_size > 0
      nessie_port    = var.nessie_port
      nessie_image   = var.nessie_image
    })
  }

  # Новый выпуск образа в семействе не должен пересоздавать работающие ВМ.
  # Обновление образа — осознанное действие: terraform apply -replace.
  lifecycle {
    ignore_changes = [boot_disk[0].initialize_params[0].image_id]
  }
}

# ---------------------------------------------------------------------------
# Object Storage: бакет Lakehouse, зашифрованный ключом KMS
# ---------------------------------------------------------------------------

resource "yandex_kms_symmetric_key" "lakehouse" {
  name              = "${local.name_prefix}-lakehouse-key"
  description       = "Ключ шифрования бакета Lakehouse"
  default_algorithm = "AES_256"
  rotation_period   = var.kms_rotation_period
  labels            = local.common_labels
}

resource "yandex_storage_bucket" "lakehouse" {
  bucket                = "${local.name_prefix}-lakehouse-${local.folder_id}"
  folder_id             = local.folder_id
  max_size              = var.lakehouse_bucket_max_size_gb * 1024 * 1024 * 1024
  default_storage_class = "STANDARD"
  force_destroy         = true

  anonymous_access_flags {
    read        = false
    list        = false
    config_read = false
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        kms_master_key_id = yandex_kms_symmetric_key.lakehouse.id
        sse_algorithm     = "aws:kms"
      }
    }
  }

  tags = local.common_labels
}
