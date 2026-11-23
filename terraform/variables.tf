variable "proxmox_endpoint" {
  description = "Proxmox API URL, ex: https://192.168.1.12:8006"
  type        = string
  default     = "https://192.168.1.12:8006"
}

variable "proxmox_api_token" {
  description = "API token Proxmox, format: user@realm!tokenid=secret"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "Clé SSH publique injectée dans les VMs via cloud-init"
  type        = string
}

variable "template_id" {
  description = "VM ID du template Debian 13 à cloner"
  type        = number
  default     = 9004
}

variable "proxmox_node" {
  description = "Nom du nœud Proxmox"
  type        = string
  default     = "pve"
}

variable "datastore_id" {
  description = "Storage Proxmox pour les VMs (ex: local-lvm, local-zfs)"
  type        = string
  default     = "local-lvm"
}

variable "network_bridge" {
  description = "Bridge réseau des VMs"
  type        = string
  default     = "vmbr0"
}
