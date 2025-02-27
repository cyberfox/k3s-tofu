# k3s-worker.tf

locals {
  one_worker_vms = {
    for node in var.worker_hosts :
      "k3s-worker-${index(var.worker_hosts, node)*3 + 1}" => node
  }
  two_worker_vms = {
    for node in var.worker_hosts :
      "k3s-worker-${index(var.worker_hosts, node)*3 + 2}" => node
  }
  three_worker_vms = {
    for node in var.worker_hosts :
      "k3s-worker-${index(var.worker_hosts, node)*3 + 3}" => node
  }

  all_worker_vms = merge(local.one_worker_vms, local.two_worker_vms, local.three_worker_vms)
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
  - name: worker
    groups:
      - sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - ${trimspace(data.local_file.ssh_public_key.content)}
    sudo: ALL=(ALL) NOPASSWD:ALL
runcmd:
  - hostname ${each.key}
  - echo "${each.key}" > /etc/hostname
  - apt update
  - apt install -y qemu-guest-agent net-tools apt-transport-https curl
  - timedatectl set-timezone America/Los_Angeles
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - swapoff -a
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
    cores = 4
  }

  memory {
    dedicated = 16384
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image[each.value].id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 30
  }

  # Master nodes start with 10.0.10.101 (first master) and go up from
  # there, stopping at .109; .110 and up to 199 are
  # workers. 10.0.10.100 is the HAProxy.
  initialization {
    dns {
      servers = ["10.0.1.10", "8.8.8.8", "75.75.75.75"]
    }
    ip_config {
      ipv4 {
        address = "10.0.10.${index(keys(local.all_worker_vms), each.key)+110}/24"
	gateway = "10.0.10.1"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.k3s_worker[each.key].id
  }

  network_device {
    bridge = "vmbr30"
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
      host = "10.0.10.${110+index(keys(proxmox_virtual_environment_vm.k3s_worker), each.key)}"
      user        = "worker"
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
    for k, v in proxmox_virtual_environment_vm.k3s_worker : k => "10.0.10.${110+index(keys(proxmox_virtual_environment_vm.k3s_worker), k)}"
  }
}

# Output worker node IPs
output "k3s_worker_ips" {
  value = local.k3s_worker_ips
}
