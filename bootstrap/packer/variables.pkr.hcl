# bootstrap/packer/variables.pkr.hcl
# Input variables for the Debian 12 golden image build.

variable "iso_url" {
  type    = string
  # Pinned to 12.9.0 (latest 12.x point release before Debian moved cdimage
  # current/ to 13.x in mid-2026). Bump when 12.10.0 ships, or migrate to
  # Debian 13 separately (will require role-compatibility testing).
  default = "https://cdimage.debian.org/cdimage/archive/12.9.0/amd64/iso-cd/debian-12.9.0-amd64-netinst.iso"
}

variable "iso_checksum" {
  type    = string
  # SHA256SUMS at https://cdimage.debian.org/cdimage/archive/12.9.0/amd64/iso-cd/SHA256SUMS
  default = "sha256:1257373c706d8c07e6917942736a865dfff557d21d76ea3040bb1039eb72a054"
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
