locals {
  k3s_master_additional_ips = [
    for k, v in proxmox_virtual_environment_vm.k3s_master_additional :
    element([
      for ip in flatten(v.ipv4_addresses) :
      ip if can(regex("^10\\.0\\.1\\.", ip))
    ], 0)
  ]
}

# Cloud-init for additional master nodes
resource "proxmox_virtual_environment_file" "k3s_master_additional" {
  for_each     = toset(slice(var.master_nodes, 1, length(var.master_nodes)))
  content_type = "snippets"
  datastore_id = "local"
  node_name    = each.key

  source_raw {
    data = <<EOF
#cloud-config
users:
  - default
  - name: k8smain
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
  - hostname k3s-main-${index(var.master_nodes, each.key)+1}
  - echo "k3s-main-${index(var.master_nodes, each.key)+1}" > /etc/hostname
  - echo "done" > /tmp/cloud-config.done
EOF

    file_name = "cloud-config-master-${each.key}.yaml"
  }
}

# Additional master nodes VMs
resource "proxmox_virtual_environment_vm" "k3s_master_additional" {
  for_each  = toset(slice(var.master_nodes, 1, length(var.master_nodes)))
  name      = "k3s-master-${each.key}"
  node_name = each.key

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
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image[each.key].id
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

    user_data_file_id = proxmox_virtual_environment_file.k3s_master_additional[each.key].id
  }

  network_device {
    bridge = "vmbr0"
  }
}

# Install k3s on additional master nodes
resource "null_resource" "install_k3s_on_additional_masters" {
  for_each = proxmox_virtual_environment_vm.k3s_master_additional

  depends_on = [
    proxmox_virtual_environment_vm.k3s_master_init,
    proxmox_virtual_environment_vm.k3s_master_additional,
  ]

  provisioner "remote-exec" {
    connection {
      host        = element([
        for ip in flatten(each.value.ipv4_addresses) :
        ip if can(regex("^10\\.0\\.1\\.", ip))
      ], 0)
      user        = "k8smain"
      private_key = file("~/.ssh/id_rsa")
    }

    inline = [
      # Wait for cloud-init to finish
      "while [ ! -f /tmp/cloud-config.done ]; do sleep 5; done",
      # Install k3s server and join cluster
      "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server' K3S_URL='https://${local.k3s_master_init_ip}:6443' K3S_TOKEN='${random_password.k3s_token.result}' sh -",
      "sudo echo 'done' > /tmp/k3s-join.done"
    ]
  }
}
