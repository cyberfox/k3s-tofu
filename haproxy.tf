variable "haproxy_node" {
  default = "proxmox-1"
}

# Cloud-init for HAProxy node
resource "proxmox_virtual_environment_file" "haproxy" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.haproxy_node

  source_raw {
    data = <<EOF
#cloud-config
users:
  - default
  - name: haproxy
    groups:
      - sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - ${trimspace(data.local_file.ssh_public_key.content)}
    sudo: ALL=(ALL) NOPASSWD:ALL
runcmd:
  - hostname haproxy
  - echo "haproxy" > /etc/hostname
  - apt update
  - apt install -y qemu-guest-agent net-tools apt-transport-https curl haproxy
  - timedatectl set-timezone America/Los_Angeles
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - swapoff -a
  - mkdir -p /etc/haproxy
  - echo "done" > /tmp/cloud-config.done
EOF

    file_name = "cloud-config-haproxy.yaml"
  }
}

#  - echo '${templatefile("${path.module}/haproxy.cfg.tpl", { master_ips = local.k3s_master_ips })}' | sudo tee /etc/haproxy/haproxy.cfg

# HAProxy VM
resource "proxmox_virtual_environment_vm" "haproxy" {
  name      = "k3s-haproxy-1"
  node_name = var.haproxy_node

  agent {
    enabled = true
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.haproxy_node].id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 10
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
        address = "10.0.10.100/24"
	gateway = "10.0.10.1"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.haproxy.id
  }

  network_device {
    bridge = "vmbr30"
    mac_address = "bc:24:11:f9:4f:50"
  }
}

resource "null_resource" "copy_haproxy_config" {
  depends_on = [
    proxmox_virtual_environment_vm.haproxy
  ]

  count = 1
  provisioner "file" {
    content     = templatefile("${path.module}/haproxy.cfg.tpl", { master_ips = local.k3s_master_ips })
    destination = "/home/haproxy/haproxy.cfg"  # Adjust the destination path as needed
  }

  provisioner "local-exec" {
    command = "echo '${templatefile("${path.module}/haproxy.cfg.tpl", { master_ips = local.k3s_master_ips })}'"
  }

  connection {
    type        = "ssh"
    host        = "10.0.10.100"
    user        = "haproxy"  # Use the appropriate user for your HAProxy server
    private_key = file("~/.ssh/id_rsa")
  }

  triggers = {
    always_run = "${timestamp()}"  # Ensures the provisioner always runs
  }
}

resource "null_resource" "restart_haproxy" {
  depends_on = [null_resource.copy_haproxy_config]

  count = 1
  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = "10.0.10.100"
      user        = "haproxy"  # Use the appropriate user
      private_key = file("~/.ssh/id_rsa")
    }

    inline = [
      "sudo mkdir -p /etc/haproxy",
      "sudo cp /home/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg",
      "sudo diff /etc/haproxy/haproxy.cfg /home/haproxy/haproxy.cfg || sudo systemctl restart haproxy"
    ]
  }

  triggers = {
    always_run = "${timestamp()}"  # Ensures the provisioner always runs
  }
}


# Output HAProxy IP

locals {
  haproxy_ip = "10.0.10.100"
}

output "haproxy_ip" {
  value = local.haproxy_ip
}

