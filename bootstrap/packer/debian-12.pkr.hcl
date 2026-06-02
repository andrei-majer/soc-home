# bootstrap/packer/debian-12.pkr.hcl
# Builds the SOC lab Debian 12 golden box for VirtualBox.

packer {
  required_plugins {
    virtualbox = {
      source  = "github.com/hashicorp/virtualbox"
      version = "~> 1"
    }
    vagrant = {
      source  = "github.com/hashicorp/vagrant"
      version = "~> 1"
    }
  }
}

source "virtualbox-iso" "debian12" {
  vm_name          = var.vm_name
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  guest_os_type    = "Debian_64"
  memory           = var.memory_mb
  cpus             = var.cpus
  disk_size        = var.disk_size_mb
  output_directory = var.output_directory
  headless         = true

  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "60m"

  shutdown_command = "echo 'vagrant' | sudo -S shutdown -P now"

  http_directory = "http"

  boot_wait = "5s"
  boot_command = [
    "<esc><wait>",
    "auto <wait>",
    "preseed/url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg <wait>",
    "debian-installer=en_US.UTF-8 <wait>",
    "auto <wait>",
    "locale=en_US.UTF-8 <wait>",
    "kbd-chooser/method=us <wait>",
    "keyboard-configuration/xkb-keymap=us <wait>",
    "netcfg/get_hostname=soc-lab-template <wait>",
    "netcfg/get_domain=soc.local <wait>",
    "fb=false <wait>",
    "debconf/frontend=noninteractive <wait>",
    "console-setup/ask_detect=false <wait>",
    "console-keymaps-at/keymap=us <wait>",
    "<enter><wait>"
  ]

  vboxmanage = [
    ["modifyvm", "{{.Name}}", "--audio-driver", "none"],
    ["modifyvm", "{{.Name}}", "--usb", "off"],
    ["modifyvm", "{{.Name}}", "--biosbootmenu", "disabled"],
    ["modifyvm", "{{.Name}}", "--firmware", "bios"]
  ]
}

build {
  name    = "soc-lab"
  sources = ["source.virtualbox-iso.debian12"]

  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | sudo -S env {{ .Vars }} {{ .Path }}"
    scripts = [
      "scripts/00-update.sh",
      "scripts/10-base-packages.sh",
      "scripts/20-ssh-key.sh",
      "scripts/30-first-boot.sh",
      "scripts/90-cleanup.sh"
    ]
  }

  post-processor "vagrant" {
    output = "soc-lab-debian-12.box"
  }
}
