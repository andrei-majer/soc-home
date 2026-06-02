#!/usr/bin/env bash
# Provisioner: refresh apt indices and full-upgrade the base image.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y dist-upgrade
apt-get -y autoremove
