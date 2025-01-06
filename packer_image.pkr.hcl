variable "initial-user" {
  type    = string
  default = "ubuntu"
}

variable "proxmox-password" {
  type    = string
  default = ""
}

variable "proxmox-username" {
  type    = string
  default = ""
}

# "timestamp" template function replacement
locals { timestamp = regex_replace(timestamp(), "[- TZ:]", "") }

# source blocks are generated from your builders; a source can be referenced in
# build blocks. A build block runs provisioner and post-processors on a
# source. Read the documentation for source blocks here:
# https://www.packer.io/docs/from-1.5/blocks/source

source "proxmox" "templatized_vm" {
  boot_command = [
    "<esc><wait>c<wait>",
    "linux /casper/vmlinuz auto=true priority=critical --- autoinstall ds='nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort}}/'<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]
  boot_wait               = "10s"
  boot_key_interval       = "200ms"
  cloud_init_storage_pool = "bigstore"
  sockets                 = 2
  cores                   = 2
  cpu_type                = "host"
  disks {
    disk_size    = "30G"
    format       = "raw"
    storage_pool = "bigstore"
    storage_pool_type = "btrfs"
    type         = "virtio"
  }
  network_adapters {
    bridge = "vmbr0"
    model  = "virtio"
  }
  http_directory   = "http"
  iso_checksum     = "sha256:9bc6028870aef3f74f4e16b900008179e78b130e6b0b9a140635434a46aa98b0"
  iso_storage_pool = "bigstore"
  iso_url          = "https://releases.ubuntu.com/22.04.5/ubuntu-22.04.5-live-server-amd64.iso"
  memory           = 2048
  node             = "proxmox-2"
  unmount_iso      = true
  onboot           = true
  boot             = "order=virtio0;ide2"

  username         = "${var.proxmox-username}"
  password         = "${var.proxmox-password}"
  proxmox_url      = "https://proxmox-2.yiff.org:8006/api2/json"

  qemu_agent       = true
  ssh_private_key_file = "/home/mrs/.ssh/id_ed25519"
  ssh_username     = "ubuntu"
  ssh_password     = "masonic"
  ssh_wait_timeout = "10m"

  vm_id            = 192
  vm_name          = "packer-k3s-vm"
  template_name    = "k3s-template"
}

# a build block invokes sources and runs provisioning steps on them. The
# documentation for build blocks can be found here:
# https://www.packer.io/docs/from-1.5/blocks/build
build {
  sources = ["source.proxmox.templatized_vm"]

  provisioner "shell" {
    inline = [
      "sudo apt update",
      "sudo apt install -y emacs-nox net-tools apt-transport-https curl nmap silversearcher-ag curl wget git vim apt-transport-https ca-certificates",
      "sudo timedatectl set-timezone America/Los_Angeles",
      "sudo swapoff -a"
    ]
  }
}
