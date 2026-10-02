variable "cloud_id" {
  description = "ID облака. Если null — берётся из переменной окружения YC_CLOUD_ID"
  type        = string
  default     = null
}

variable "folder_id" {
  description = "ID каталога. Если null — берётся из переменной окружения YC_FOLDER_ID"
  type        = string
  default     = null
}

variable "default_zone" {
  description = "Зона доступности по умолчанию"
  type        = string
  default     = "ru-central1-a"
}

variable "project" {
  description = "Префикс имён ресурсов"
  type        = string
  default     = "future20"
}

variable "environment" {
  description = "Окружение: dev, stage, prod"
  type        = string
  default     = "dev"
}

variable "subnets" {
  description = "Подсети доменной среды. private = true — подсеть без публичных адресов, выход в интернет через NAT-шлюз"
  type = map(object({
    zone    = string
    cidr    = string
    private = bool
  }))
}

variable "admin_cidrs" {
  description = "Сети, из которых разрешён SSH на bastion. Реальный адрес администратора задаётся в локальном admin.auto.tfvars"
  type        = list(string)
}

variable "security_groups" {
  description = "Группы безопасности. Источник входящего трафика — подсети среды (from_subnets), ВМ с фиксированным адресом (from_vms) и/или сети администраторов (from_admin). Назначение исходящего — подсети среды (to_subnets) и/или адреса (to_cidrs); без egress разрешён весь исходящий трафик"
  type = map(object({
    description = string
    ingress = list(object({
      description  = string
      protocol     = string
      port         = optional(number)
      from_subnets = optional(list(string), [])
      from_vms     = optional(list(string), [])
      from_admin   = optional(bool, false)
    }))
    egress = optional(list(object({
      description = string
      protocol    = string
      port        = optional(number)
      to_subnets  = optional(list(string), [])
      to_cidrs    = optional(list(string), [])
      })), [
      { description = "Весь исходящий трафик", protocol = "ANY", port = null, to_subnets = [], to_cidrs = ["0.0.0.0/0"] },
    ])
  }))

  validation {
    condition = alltrue(flatten([
      for sg in values(var.security_groups) : concat(
        [for rule in sg.ingress : [for s in rule.from_subnets : contains(keys(var.subnets), s)]],
        [for rule in sg.egress : [for s in rule.to_subnets : contains(keys(var.subnets), s)]]
      )
    ]))
    error_message = "from_subnets и to_subnets в правилах групп безопасности должны ссылаться на ключи из переменной subnets."
  }
}

variable "nessie_image" {
  description = "Docker-образ каталога Nessie с зафиксированной версией"
  type        = string
  default     = "ghcr.io/projectnessie/nessie:0.108.8"
}

variable "nessie_port" {
  description = "Порт REST API каталога Nessie. Правило доступа к нему добавляется в группу безопасности ВМ с ролью nessie автоматически"
  type        = number
  default     = 19120
}

variable "nessie_api_sources" {
  description = "Откуда разрешены запросы к REST API Nessie: подсети среды и ВМ с фиксированным адресом"
  type = object({
    from_subnets = optional(list(string), [])
    from_vms     = optional(list(string), [])
  })
  default = {}

  validation {
    condition     = alltrue([for s in var.nessie_api_sources.from_subnets : contains(keys(var.subnets), s)])
    error_message = "nessie_api_sources.from_subnets должны ссылаться на ключи из переменной subnets."
  }

  validation {
    condition     = alltrue([for vm in var.nessie_api_sources.from_vms : contains(keys(var.vms), vm) && try(var.vms[vm].ip_address != null, false)])
    error_message = "nessie_api_sources.from_vms должны ссылаться на ВМ из переменной vms с заданным ip_address."
  }
}

variable "image_family" {
  description = "Семейство образа ОС для ВМ"
  type        = string
  default     = "ubuntu-2204-lts"
}

variable "platform_id" {
  description = "Платформа (поколение процессоров) ВМ"
  type        = string
  default     = "standard-v3"
}

variable "vm_user" {
  description = "Пользователь для SSH-доступа к ВМ"
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key_path" {
  description = "Путь к публичному SSH-ключу администратора"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "vms" {
  description = "Виртуальные машины доменной среды"
  type = map(object({
    subnet         = string
    ip_address     = optional(string)
    security_group = string
    role           = string
    cores          = number
    memory         = number
    core_fraction  = number
    boot_disk_size = number
    boot_disk_type = string
    data_disk_size = number
    data_disk_type = string
    public_ip      = bool
    preemptible    = bool
  }))

  validation {
    condition     = alltrue([for vm in values(var.vms) : contains(["bastion", "nessie", "clinic-adapter", "service"], vm.role)])
    error_message = "role определяет начальную настройку ВМ в cloud-init и должна быть одной из: bastion, nessie, clinic-adapter, service."
  }

  validation {
    condition     = alltrue([for vm in values(var.vms) : contains(keys(var.subnets), vm.subnet)])
    error_message = "subnet каждой ВМ должна быть ключом из переменной subnets."
  }

  validation {
    condition     = alltrue([for vm in values(var.vms) : contains(keys(var.security_groups), vm.security_group)])
    error_message = "security_group каждой ВМ должна быть ключом из переменной security_groups."
  }
}

variable "kms_rotation_period" {
  description = "Период автоматической ротации ключа KMS бакета Lakehouse"
  type        = string
  default     = "8760h"
}

variable "lakehouse_bucket_max_size_gb" {
  description = "Ограничение размера бакета Lakehouse, ГБ"
  type        = number
  default     = 10
}
