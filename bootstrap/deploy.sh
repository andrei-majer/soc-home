#!/usr/bin/env bash
# bootstrap/deploy.sh - Linux mirror of deploy.ps1
# Phase 1B: DR mode only, no restore phase.

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [--mode dr|isolated] [--phase image|vms|converge|restore|all]
          [--skip-restore] [--hosts list] [--profile full|minimal]
          [--override-mtu N] [--bridged-nic NAME]
          [--force-image] [--force-wifi-bridge] [--overwrite-existing] [--force]

See bootstrap/README.md for details.
EOF
  exit 1
}

MODE=dr; PHASE=all; SKIP_RESTORE=0; HOSTS=""; PROFILE=full
OVERRIDE_MTU=0; BRIDGED_NIC=""; FORCE_IMAGE=0; FORCE_WIFI=0; OVERWRITE=0; FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)               MODE="$2"; shift 2;;
    --phase)              PHASE="$2"; shift 2;;
    --skip-restore)       SKIP_RESTORE=1; shift;;
    --hosts)              HOSTS="$2"; shift 2;;
    --profile)            PROFILE="$2"; shift 2;;
    --override-mtu)       OVERRIDE_MTU="$2"; shift 2;;
    --bridged-nic)        BRIDGED_NIC="$2"; shift 2;;
    --force-image)        FORCE_IMAGE=1; shift;;
    --force-wifi-bridge)  FORCE_WIFI=1; shift;;
    --overwrite-existing) OVERWRITE=1; shift;;
    --force)              FORCE=1; shift;;
    -h|--help)            usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done

BOOTSTRAP_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${BOOTSTRAP_ROOT}/logs"
mkdir -p "${LOG_DIR}"
LOG="${LOG_DIR}/deploy-$(date +%Y%m%d-%H%M%S).log"

step() { local m="[$(date +%FT%T)] $*"; echo "${m}" | tee -a "${LOG}"; }
fail() { step "FAIL: $*"; exit 1; }

step "deploy.sh starting - Mode=${MODE} Phase=${PHASE} Hosts='${HOSTS}' Profile=${PROFILE}"

[[ "${MODE}" == "isolated" ]] && fail "isolated mode is Phase 2"

preflight() {
  step "preflight"
  command -v VBoxManage >/dev/null || fail "VBoxManage not found - install VirtualBox"
  step "  VBox: $(VBoxManage --version)"
  command -v packer  >/dev/null || fail "packer not in PATH"
  command -v vagrant >/dev/null || fail "vagrant not in PATH"

  for f in vault_pass.txt id_ed25519 id_ed25519.pub; do
    [[ -r "${BOOTSTRAP_ROOT}/secrets/${f}" ]] || fail "secrets/${f} missing"
  done
  step "  secrets/: present"

  if [[ "${MODE}" == "dr" ]]; then
    if [[ -z "${BRIDGED_NIC}" ]]; then
      local cache="${BOOTSTRAP_ROOT}/.deploy-config.local"
      if [[ -r "${cache}" ]]; then
        BRIDGED_NIC=$(grep ^BridgedNic= "${cache}" | cut -d= -f2)
      fi
      if [[ -z "${BRIDGED_NIC}" ]]; then
        BRIDGED_NIC=$(ip -o route show default 2>/dev/null | awk '{print $5}' | head -1)
        [[ -z "${BRIDGED_NIC}" ]] && fail "could not autodetect bridged NIC - pass --bridged-nic"
        echo "BridgedNic=${BRIDGED_NIC}" > "${cache}"
        step "  bridged NIC autodetected: ${BRIDGED_NIC} (cached)"
      else
        step "  bridged NIC: ${BRIDGED_NIC} (from cache or flag)"
      fi
    else
      step "  bridged NIC: ${BRIDGED_NIC} (from --bridged-nic)"
    fi
    local mtu
    mtu=$(cat "/sys/class/net/${BRIDGED_NIC}/mtu" 2>/dev/null || echo 0)
    step "  bridge MTU: ${mtu}"
    if (( OVERRIDE_MTU == 0 )) && (( mtu < 1500 )); then
      fail "bridge MTU ${mtu} < 1500 (VPN on bridge?). Disable VPN or pass --override-mtu ${mtu}"
    fi
    export SOC_BRIDGED_NIC="${BRIDGED_NIC}"
  fi
  step "preflight: PASS"
}

phase_image() {
  step "phase image"
  local packer_dir="${BOOTSTRAP_ROOT}/packer"
  local box="${packer_dir}/soc-lab-debian-12.box"
  local hashfile="${packer_dir}/soc-lab-debian-12.box.sha"
  local current_hash
  current_hash=$(find "${packer_dir}" -type f ! -name '*.box' ! -name '*.sha' \
                    ! -path '*output-*' ! -path '*packer_cache*' \
                    -exec sha256sum {} + | sort | sha256sum | awk '{print $1}')

  if [[ -f "${box}" && -f "${hashfile}" && "${FORCE_IMAGE}" -eq 0 ]]; then
    if [[ "$(cat "${hashfile}")" == "${current_hash}" ]]; then
      step "  image up to date - skipping build"
      return
    fi
  fi
  (cd "${packer_dir}" && packer init . && packer build -force .)
  [[ -f "${box}" ]] || fail "packer reported success but .box missing"
  echo "${current_hash}" > "${hashfile}"
  vagrant box add --force soc-lab/debian-12 "${box}"
}

phase_vms() {
  step "phase vms"
  export SOC_MODE="${MODE}" SOC_HOSTS="${HOSTS}" SOC_PROFILE="${PROFILE}"
  cd "${BOOTSTRAP_ROOT}/vagrant"
  # `vagrant up` will likely return non-zero because its built-in SSH probe
  # times out (Vagrant 2.4.9 doesn't accept communicator=:none; VBox NAT
  # loopback is unreliable; the Vagrant insecure key isn't wired for root).
  # The VM boots regardless - that's all we need. soc-first-boot.service inside
  # the VM applies hostname/IP/mode/ssh-key from DMI strings; Ansible reaches
  # each VM via its bridged IP next phase. Deliberately NO `vagrant provision`
  # (mirrors deploy.ps1 Invoke-PhaseVms): provisioning over the NAT-SSH path is
  # exactly what we're avoiding. Just settle-wait for first-boot to finish.
  if [[ -n "${HOSTS}" ]]; then
    vagrant up --no-provision ${HOSTS//,/ } || \
      step "  vagrant up exit=$? (expected SSH-timeout - VMs still boot, proceeding)"
  else
    vagrant up --no-provision || \
      step "  vagrant up exit=$? (expected SSH-timeout - VMs still boot, proceeding)"
  fi
  step "  VMs created. Waiting 60s for first-boot service to apply networking..."
  sleep 60
  step "  VMs should now be reachable on per-VM bridged IPs"
}

phase_converge() {
  step "phase converge"
  command -v ansible-playbook >/dev/null || fail "ansible-playbook not in PATH"
  local repo_root inv_primary inv_overrides
  repo_root="$(cd "${BOOTSTRAP_ROOT}/.." && pwd)"
  inv_primary="${repo_root}/ansible/inventory/hosts.yml"
  inv_overrides="${BOOTSTRAP_ROOT}/.vagrant/ansible-overrides"
  [[ -f "${inv_primary}" ]]  || fail "primary inventory missing at ${inv_primary}"
  [[ -d "${inv_overrides}" ]] || fail "inventory overrides not generated - did vms phase run?"

  local limit_args=()
  [[ -n "${HOSTS}" ]] && limit_args=(--limit "${HOSTS}")

  ansible-playbook \
    "${repo_root}/ansible/playbooks/site.yml" \
    -i "${inv_primary}" -i "${inv_overrides}" \
    --vault-password-file "${BOOTSTRAP_ROOT}/secrets/vault_pass.txt" \
    --private-key "${BOOTSTRAP_ROOT}/secrets/id_ed25519" \
    "${limit_args[@]}"
}

phase_restore() {
  step "phase restore: no-op in Phase 1B (ships in Phase 2)"
}

preflight

case "${PHASE}" in
  image)    phase_image;;
  vms)      phase_vms;;
  converge) phase_converge;;
  restore)  phase_restore;;
  all)
    phase_image
    phase_vms
    phase_converge
    if [[ "${SKIP_RESTORE}" -eq 0 ]]; then phase_restore; fi
    ;;
  *) fail "unknown phase ${PHASE}";;
esac

step "deploy.sh complete"
