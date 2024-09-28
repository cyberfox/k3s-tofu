# k3s-workers.tf
#k3s-worker-proxmox-4
locals {
  existing_worker_vms = {
    for node in var.worker_nodes :
        node => node
#    "k3s-worker-${node}" => node
  }
}

locals {
  new_worker_vms = {
    for node in var.worker_nodes :
    "k3s-worker-new-${index(var.worker_nodes, node) + 1}" => node
  }
}

locals {
  all_worker_vms = merge(local.existing_worker_vms, local.new_worker_vms)
}

# Cloud-init for worker nodes
resource "proxmox_virtual_environment_file" "k3s_worker" {
  for_each     = local.all_worker_vms
  content_type = "snippets"
  datastore_id = "local"
  node_name    = each.value

  source_raw {
    data = <<EOF
#cloud-config
users:
  - default
  - name: k8sworker
    groups:
      - sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - ${trimspace(data.local_file.ssh_public_key.content)}
    sudo: ALL=(ALL) NOPASSWD:ALL
runcmd:
  - apt update
  - apt install -y qemu-guest-agent net-tools apt-transport-https curl
  - timedatectl set-timezone America/Los_Angeles
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - swapoff -a
  - hostname ${each.key}
  - echo "done" > /tmp/cloud-config.done
EOF

    file_name = "cloud-config-worker-${each.key}.yaml"
  }
}

# Worker nodes VMs
resource "proxmox_virtual_environment_vm" "k3s_worker" {
  for_each  = local.all_worker_vms
  name      = can(regex("^proxmox-", each.key) == "proxmox-") ? "k3s-worker-${each.key}" : each.key
  node_name = each.value

  lifecycle {
     ignore_changes = all
  }
#    prevent_destroy = true

  agent {
    enabled = true
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image[each.value].id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 30
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.k3s_worker[each.key].id
  }

  network_device {
    bridge = "vmbr0"
  }
}

# Install k3s agent on worker nodes
resource "null_resource" "install_k3s_on_workers" {
  depends_on = [
    proxmox_virtual_environment_vm.k3s_worker,
    proxmox_virtual_environment_vm.haproxy,
  ]

  for_each = proxmox_virtual_environment_vm.k3s_worker

  provisioner "remote-exec" {
    connection {
      host        = element([
        for ip in flatten(each.value.ipv4_addresses) :
        ip if can(regex("^10\\.0\\.1\\.", ip))
      ], 0)
      user        = "k8sworker"
      private_key = file("~/.ssh/id_rsa")
    }

    inline = [
      # Wait for cloud-init to finish
      "while [ ! -f /tmp/cloud-config.done ]; do sleep 5; done",
      "sudo echo 'done' > /tmp/while.done",
      # Install k3s agent and join cluster via HAProxy
      "curl -sfL https://get.k3s.io | K3S_URL='https://${local.haproxy_ip}:6443' K3S_TOKEN='${random_password.k3s_token.result}' sh -",
      "sudo echo 'done' > /tmp/k3s-join.done"
    ]
  }
}

locals {
  k3s_worker_ips = {
    for k, v in proxmox_virtual_environment_vm.k3s_worker :
    k => element([
      for ip in flatten(v.ipv4_addresses) :
      ip if can(regex("^10\\.0\\.1\\.", ip))
    ], 0)
  }
}

# Output worker node IPs
output "k3s_worker_ips" {
  value = local.k3s_worker_ips
}
