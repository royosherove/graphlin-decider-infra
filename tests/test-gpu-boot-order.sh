#!/bin/bash
# Offline test: nvidia-uvm must be loaded before decider.service starts.
# Language: ASD-STE100.
#
# systemd reads the device numbers for DeviceAllow=char-nvidia-uvm when the unit starts,
# before ExecStartPre. If nvidia-uvm is not loaded at that time (for example after a reboot),
# the first start fails with "CUDA unknown error". Then Restart=on-failure starts the unit again.
#
# This test reads the files of the boot bundle. It needs no GPU and makes no network call.
#   1. The install script writes nvidia-uvm to a file in /etc/modules-load.d.
#   2. The install script loads nvidia-uvm and checks /proc/devices before the first
#      "systemctl start decider.service".
#   3. decider.service starts after systemd-modules-load.service and allows char-nvidia-uvm.
#   4. The bundle form of the files (bin/decider-aws removes the comment lines) keeps 1 to 3.
# Usage: tests/test-gpu-boot-order.sh
set -u -o pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALL=$ROOT/bootstrap/install-decider.sh
UNIT=$ROOT/bootstrap/systemd/decider.service
FAILS=0

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }

# The same filter as build_user_data in bin/decider-aws: no comment lines in the bundle.
bundle_form() { sed -e '/^[[:space:]]*#[^!]/d' -e '/^[[:space:]]*#$/d' "$1"; }

check_files() { # LABEL INSTALL_TEXT UNIT_TEXT
  local label=$1 install=$2 unit=$3 load start check after
  if grep -Eq '^echo nvidia-uvm > /etc/modules-load\.d/[a-z0-9-]+\.conf$' <<< "$install"; then
    pass "$label 1: the install writes nvidia-uvm to /etc/modules-load.d"
  else
    fail "$label 1: no 'echo nvidia-uvm > /etc/modules-load.d/NAME.conf' line"
  fi

  load=$(printf '%s\n' "$install" | grep -n -E '^(modprobe nvidia-uvm|/usr/bin/nvidia-modprobe -u)' | head -n 1 | cut -d: -f1)
  check=$(printf '%s\n' "$install" | grep -n -F "grep -q ' nvidia-uvm\$' /proc/devices" | head -n 1 | cut -d: -f1)
  start=$(printf '%s\n' "$install" | grep -n -E '^systemctl (start|enable --now|restart) decider\.service' | head -n 1 | cut -d: -f1)
  if [ -z "$start" ]; then
    fail "$label 2: no 'systemctl start decider.service' line"
  elif [ -n "$load" ] && [ -n "$check" ] && [ "$load" -lt "$check" ] && [ "$check" -lt "$start" ]; then
    pass "$label 2: load (line $load) and /proc/devices check (line $check) before the start (line $start)"
  else
    fail "$label 2: load='$load' check='$check' start='$start' (want load < check < start)"
  fi

  after=$(printf '%s\n' "$unit" | sed -n 's/^After=//p' | tr ' ' '\n')
  if grep -qx 'systemd-modules-load.service' <<< "$after" \
    && grep -qx 'DeviceAllow=char-nvidia-uvm rw' <<< "$unit"; then
    pass "$label 3: decider.service is After=systemd-modules-load.service and allows char-nvidia-uvm"
  else
    fail "$label 3: decider.service needs After=systemd-modules-load.service and DeviceAllow=char-nvidia-uvm rw"
  fi
}

check_files repository "$(cat "$INSTALL")" "$(cat "$UNIT")"
check_files bundle "$(bundle_form "$INSTALL")" "$(bundle_form "$UNIT")"
# Check 4 is the "bundle" run of checks 1 to 3.

if [ "$FAILS" -eq 0 ]; then echo "RESULT PASS"; exit 0; fi
echo "RESULT FAIL ($FAILS)"
exit 1
