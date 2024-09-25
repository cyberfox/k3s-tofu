terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.50.0"
    }
  }
}

provider "proxmox" {
  endpoint = var.virtual_environment.endpoint
  username = var.virtual_environment.username
  password = var.virtual_environment.password

  insecure = true
  tmp_dir  = "/var/tmp"

  ssh {
    agent       = true
    private_key = file("~/.ssh/id_rsa")
  }
}

data "local_file" "ssh_public_key" {
  filename = pathexpand("~/.ssh/id_rsa.pub")
}

variable "master_nodes" {
  type    = list(string)
  default = ["proxmox-1", "proxmox-2", "proxmox-4"]
}

# Generate a random token for k3s cluster
resource "random_password" "k3s_token" {
  length  = 20
  special = false
}

variable "worker_nodes" {
  default = ["proxmox-1", "proxmox-2", "proxmox-4"]
}

# Download Ubuntu Cloud Image on all master nodes
resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  for_each     = toset(concat(var.master_nodes, var.worker_nodes))
  content_type = "iso"
  datastore_id = "local"
  node_name    = each.key

  url                 = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  overwrite           = true
  overwrite_unmanaged = true
}

# Collect master node IPs
output "k3s_master_ips" {
  value = local.k3s_master_ips
}

locals {
  k3s_master_ips = concat(
    [local.k3s_master_init_ip],
    local.k3s_master_additional_ips
  )
}
