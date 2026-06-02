# bootstrap/packer/variables.pkr.hcl
# Input variables for the Debian 12 golden image build.

variable "iso_url" {
  type    = string
  default = "https://cdimage.debian.org/debian-cd/12.5.0/amd64/iso-cd/debian-12.5.0-amd64-netinst.iso"
}

variable "iso_checksum" {
  type    = string
  # Update when bumping iso_url. SHA256SUMS at
  # https://cdimage.debian.org/debian-cd/12.5.0/amd64/iso-cd/SHA256SUMS
  default = "sha256:013f5b44670d81280b5b1bc02455842b250df2f0c6763398feb69af1a805a14f"
}

variable "vm_name" {
  type    = string
  default = "soc-lab-debian-12"
}

variable "memory_mb" {
  type    = number
  default = 2048
}

variable "cpus" {
  type    = number
  default = 2
}

variable "disk_size_mb" {
  type    = number
  default = 20480
}

variable "ssh_username" {
  type    = string
  default = "vagrant"
}

variable "ssh_password" {
  type      = string
  default   = "vagrant"
  sensitive = true
}

variable "output_directory" {
  type    = string
  default = "output-virtualbox-iso"
}
