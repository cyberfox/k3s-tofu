# k3s-main.tf

# Cloud-init for the first master node
resource "proxmox_virtual_environment_file" "k3s_master_init" {
  depends_on = [ proxmox_virtual_environment_vm.haproxy ]
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.master_nodes[0]

  source_raw {
    data = <<EOF
#cloud-config
users:
  - default
  - name: k3smain
    groups:
      - sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - ${trimspace(data.local_file.ssh_public_key.content)}
    sudo: ALL=(ALL) NOPASSWD:ALL
runcmd:
  - hostname k3s-main-1
  - echo "k3s-main-1" > /etc/hostname
  - apt update
  - apt install -y qemu-guest-agent net-tools apt-transport-https curl
  - timedatectl set-timezone America/Los_Angeles
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - swapoff -a
  - echo "done" > /tmp/cloud-config.done
EOF

    file_name = "cloud-config-master-${var.master_nodes[0]}.yaml"
  }
}

# First master node VM
resource "proxmox_virtual_environment_vm" "k3s_master_init" {
  name      = "k3s-master-${var.master_nodes[0]}"
  node_name = var.master_nodes[0]

  lifecycle {
    ignore_changes = [
      initialization[0].user_data_file_id
    ]
  }

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
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.master_nodes[0]].id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 30
  }

  # Master nodes start with 10.0.10.101 (first master) and go up from
  # there, stopping at .109; .110 and up to 199 are
  # workers. 10.0.10.100 is the HAProxy.
  initialization {
    ip_config {
      ipv4 {
        address = "10.0.10.101"
	gateway = "10.0.10.1"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.k3s_master_init.id
  }

  network_device {
    bridge = "vmbr30"
  }
}

resource "null_resource" "install_k3s_initial_server" {
  depends_on = [
    proxmox_virtual_environment_vm.k3s_master_init,
    proxmox_virtual_environment_vm.haproxy,
  ]

  lifecycle {
    ignore_changes = all
  }

  provisioner "remote-exec" {
    connection {
      host        = local.k3s_master_init_ip
      user        = "k3smain"
      private_key = file("~/.ssh/id_rsa")
    }

    inline = [
      "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=\"server --tls-san ${local.haproxy_ip} --cluster-init\" K3S_TOKEN=\"${random_password.k3s_token.result}\" sh -",
      "mkdir -p ~k3smain/.kube",
      "sudo cp -i /etc/rancher/k3s/k3s.yaml ~k3smain/.kube/config",
      "sudo chown $(id k3smain -u):$(id k3smain -g) ~k3smain/.kube ~k3smain/.kube/config",
    ]
  }

  provisioner "local-exec" {
    command = "scp -i ~/.ssh/id_rsa k3smain@${local.k3s_master_init_ip}:.kube/config ./kube_config"
  }
}

locals {
  k3s_master_init_ip = "10.0.10.101"
}

output "k3s_master_init_ip" {
  value = local.k3s_master_init_ip
}
