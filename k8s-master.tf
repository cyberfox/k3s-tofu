terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      version = "0.50.0"
    }
  }
}

provider "proxmox" {
  endpoint = var.virtual_environment.endpoint
  username = var.virtual_environment.username
  password = var.virtual_environment.password

  insecure = true
  tmp_dir = "/var/tmp"

  ssh {
    agent = true
    private_key = file("~/.ssh/id_rsa")
  }
}

data "local_file" "ssh_public_key" {
  filename = "/Users/mrs/.ssh/id_rsa.pub"
}

resource "proxmox_virtual_environment_file" "k8s_master" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "proxmox-1"

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
    lock_passwd: false
    passwd: $6$rounds=4096$/BuNt5EWDU/R3Eak$ZkeyLoSI8CFFFxYMzC04fYSOovk.BQl2pO1cm7q.SHYbJ3izSYKQwbnhjotdO80rLR7IPDBA/yvfWIUHy3vC51
runcmd:
    - apt update
    - apt install -y qemu-guest-agent net-tools apt-transport-https curl
    - timedatectl set-timezone America/Los_Angeles
    - systemctl enable qemu-guest-agent
    - systemctl start qemu-guest-agent
    - swapoff -a
    - curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
    - echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
    - curl -fsSL "https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    - apt update
    - sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    - apt install -y kubeadm kubelet kubectl kubernetes-cni
    - kubeadm init
    - kubectl apply -f "https://docs/projectcalico.org/manifests/calico.yaml"
    - mkdir -p ~k8smain/.kube
    - cp -i /etc/kubernetes/admin.conf ~k8smain/.kube/config
    - chown $(id k8smain -u)\:$(id k8smain -g) ~k8smain/.kube ~k8smain/.kube/config
    - echo "done" > /tmp/cloud-config.done
EOF

    file_name = "cloud-config.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "k8s_master" {
  name      = "k8s-master"
  node_name = "proxmox-1"

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
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 20
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.k8s_master.id
  }

  network_device {
    bridge = "vmbr0"
  }
}

resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = "proxmox-1"

  url = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
}

output "master_ipv4_address" {
  value = proxmox_virtual_environment_vm.k8s_master.ipv4_addresses[1][0]
}

resource "null_resource" "get_join_command" {
  depends_on = [proxmox_virtual_environment_vm.k8s_master]

  triggers = {
    always_run = "${timestamp()}"
  }

  provisioner "remote-exec" {
    connection {
      host = "${proxmox_virtual_environment_vm.k8s_master.ipv4_addresses[1][0]}"
      user = "k8smain"
      type = "ssh"
      private_key = file("~/.ssh/id_rsa")
    }
    inline = [
      "kubeadm token create --print-join-command > /tmp/join_command.sh"
    ]
  }

  provisioner "local-exec" {
    command = "scp k8smain@${proxmox_virtual_environment_vm.k8s_master.ipv4_addresses[1][0]}:/tmp/join_command.sh ${path.module}/join_command.sh"
  }
}
