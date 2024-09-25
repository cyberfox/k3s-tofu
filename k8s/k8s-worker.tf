variable "worker_nodes" {
  type    = list(string)
  default = ["proxmox-1", "proxmox-2", "proxmox-4"]
}

variable "worker_count_per_node" {
  default = 3
}

# Create a local map to represent all workers with their node and index
locals {
  worker_instances = flatten([
    for node in var.worker_nodes : [
      for index in range(var.worker_count_per_node) : {
        node  = node
        index = index
      }
    ]
  ])
}

resource "proxmox_virtual_environment_file" "k8s_worker" {
  for_each     = toset(var.worker_nodes)
  content_type = "snippets"
  datastore_id = "local-lvm"
  node_name    = each.key

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
    - curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
    - echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
    - curl -fsSL "https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    - apt update
    - sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    - apt install -y kubeadm kubelet kubectl kubernetes-cni
    - echo "done" > /tmp/cloud-config.done
EOF

    file_name = "cloud-config-worker-${each.key}.yaml"
  }
}

# kubeadm init phase show-join-command
# mkdir -p ~ubuntu/.kube
# cp -i /etc/kubernetes/admin.conf ~ubuntu/.kube/config
# chown $(id ubuntu -u):$(id ubuntu -g) ~ubuntu/.kube ~ubuntu/.kube/config

variable "ssh_private_key_path" {
  default = "~/.ssh/id_rsa"
}

resource "proxmox_virtual_environment_vm" "k8s_worker" {
  for_each  = { for i, worker in local.worker_instances : "${worker.node}-${worker.index}" => worker }
  name      = "k8s-worker-${each.value.node}-${each.value.index + 1}"
  node_name = each.value.node

  agent {
    enabled = true
  }

  cpu {
    cores = 4
  }

  memory {
    dedicated = 8192
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 75
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.k8s_worker[each.value.node].id
  }

  network_device {
    bridge = "vmbr0"
  }
}

output "worker_ipv4_address" {
  value = { for k, v in proxmox_virtual_environment_vm.k8s_worker : k => v.ipv4_addresses[1][0] }
}

#resource "null_resource" "afterparty" {
#  depends_on = [proxmox_virtual_environment_vm.k8s_master, proxmox_virtual_environment_vm.k8s_worker]
#  for_each = compact([for addr in proxmox_virtual_environment_vm.k8s_worker[*] : addr.ipv4_addresses[1][0]])
#
#  provisioner "local-exec" {
#    # Replace with the appropriate command to copy the join_command.sh file to your VM
#    # and then SSH into the VM to execute it. Adjust user, VM IP, and paths as necessary.
#    command = <<EOF
#      scp ${path.module}/join_command.sh k8sworker@${each.value}:~/join_command.sh &&
#      ssh k8sworker@${each.value} 'bash ~/join_command.sh'
#    EOF
#  }
#}