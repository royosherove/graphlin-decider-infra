#!/bin/bash
# install-decider.sh: first-boot install of the Strands Decider GPU host.
#
# Target: "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)" on g6.xlarge or g5.xlarge.
# bin/decider-aws puts this file and the other bundle files in the EC2 user data.
# cloud-init runs it one time, as root, from /opt/decider/bundle.
#
# Order:
#   1. The guard units first: decider-maxrun.timer (poweroff 8 h after boot) and
#      decider-idle.timer (idle poweroff). systemd starts them at each boot.
#   2. Packages from the hashed lock (--require-hashes --only-binary :all:), then the
#      strands-decider git package last, with --no-deps.
#   3. The model files at the pinned revisions, checked with the SHA-256 manifest.
#   4. decider-serve and decider.service. The install writes /var/lib/decider/INSTALLED.
#      Then it starts the service. The service does its own identity checks and warm-up.
#
# Logs: /var/log/decider-install.log. Phase times: /var/lib/decider/install-phases.log.
# When a step fails, the script writes /var/lib/decider/FAILED and stops.
# Language: ASD-STE100.
set -euo pipefail

# ---------------------------------------------------------------------------------------------
# Pins. Change a pin only after a test of the new value on a GPU host.
# ---------------------------------------------------------------------------------------------
UV_VERSION=0.12.23
UV_SHA256=9167d72b3319674b6303c4cbe071854bba13ebdf3d76b1a7cbdc175471fb66d6
PYTHON_VERSION=3.12
PYPI_INDEX=https://pypi.org/simple
TORCH_INDEX=https://download.pytorch.org/whl/cu126
DECIDER_GIT=https://github.com/strands-labs/strands-decider
DECIDER_COMMIT=75c9fd32e664954cdc18481434018aa507eee8fb
V19_REPO=StrandsAgents/strands-decider-2B-hobson-v19
V19_REVISION=bb282d786bc251fd4e3068de3ada9ddbb38127cd
BASE_REPO=Qwen/Qwen3.5-2B-Base
BASE_REVISION=b1485b2fa6dfa1287294f269f5fb618e03d52d7c
MODEL_NAME=strands-decider-2B-hobson-v19-bb282d7-b1485b2

BUNDLE=/opt/decider/bundle
STATE=/var/lib/decider
OPT=/opt/decider
VENV=$OPT/venv
PHASES=$STATE/install-phases.log

mkdir -p "$STATE"
exec > >(tee -a /var/log/decider-install.log) 2>&1

phase() { echo "$(date -u +%FT%TZ) $*" | tee -a "$PHASES"; }
on_error() {
  echo "$(date -u +%FT%TZ) FAILED at line $1" | tee -a "$PHASES" > "$STATE/FAILED"
}
trap 'on_error $LINENO' ERR
rm -f "$STATE/FAILED" "$STATE/INSTALLED"
phase "start bundle=$(sed -n 's/^BUNDLE_COMMIT=//p' /etc/decider/decider.env) market=$(sed -n 's/^MARKET=//p' /etc/decider/decider.env) type=$(cat /sys/devices/virtual/dmi/id/product_name 2> /dev/null || echo unknown)"

# ---------------------------------------------------------------------------------------------
# 1. Guard units first. Thus a failed install also stops the host.
# ---------------------------------------------------------------------------------------------
phase "guard units"
install -d -m 0755 "$OPT/bin"
install -m 0755 "$BUNDLE/decider-idle-check" "$OPT/bin/decider-idle-check"
for unit in decider-idle.service decider-idle.timer decider-maxrun.service decider-maxrun.timer; do
  install -m 0644 "$BUNDLE/systemd/$unit" "/etc/systemd/system/$unit"
done
systemctl daemon-reload
systemctl enable --now decider-maxrun.timer decider-idle.timer
systemctl list-timers 'decider-*' --no-pager | tee -a "$PHASES"

# sshd is not necessary: access is through SSM only.
systemctl disable --now ssh.service ssh.socket > /dev/null 2>&1 || true

# ---------------------------------------------------------------------------------------------
# 2. Service user, directories and the GPU
# ---------------------------------------------------------------------------------------------
if ! id decider > /dev/null 2>&1; then
  useradd --system --user-group --home-dir "$STATE" --shell /usr/sbin/nologin decider
fi
install -d -m 0750 -o decider -g decider "$STATE" "$STATE/hf" "$STATE/models" "$STATE/triton"
chown decider:decider "$PHASES"
for _ in $(seq 1 12); do
  if nvidia-smi > /dev/null 2>&1; then break; fi
  sleep 5
done
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | tee -a "$PHASES"
# systemd reads the device numbers for DeviceAllow=char-nvidia-uvm when
# decider.service starts, before ExecStartPre. Thus nvidia-uvm must be loaded before the
# unit starts: at each boot (systemd-modules-load.service) and now, for the first start.
echo nvidia-uvm > /etc/modules-load.d/decider.conf
modprobe nvidia-uvm
grep -q ' nvidia-uvm$' /proc/devices

# Triton compiles a small C launcher at run time. It needs a C compiler.
if ! command -v gcc > /dev/null 2>&1; then
  phase "install gcc"
  apt-get -o DPkg::Lock::Timeout=600 update
  apt-get -o DPkg::Lock::Timeout=600 install -y gcc
fi
command -v git > /dev/null 2>&1 || { phase "install git"; apt-get -o DPkg::Lock::Timeout=600 install -y git; }

# ---------------------------------------------------------------------------------------------
# 3. uv (checksum pinned) and a managed Python. A managed Python has the C headers for Triton.
# ---------------------------------------------------------------------------------------------
phase "uv $UV_VERSION"
tmp=$(mktemp -d)
curl -fsSL --retry 5 -o "$tmp/uv.tgz" \
  "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz"
echo "${UV_SHA256}  $tmp/uv.tgz" | sha256sum -c -
tar -xzf "$tmp/uv.tgz" -C "$tmp"
install -m 0755 "$tmp/uv-x86_64-unknown-linux-gnu/uv" /usr/local/bin/uv
rm -rf "$tmp"

export UV_PYTHON_INSTALL_DIR=$OPT/python
export UV_CACHE_DIR=/var/cache/decider-uv
export UV_NO_PROGRESS=1
phase "python $PYTHON_VERSION"
uv python install "$PYTHON_VERSION"
PY=$(find "$OPT/python" -maxdepth 3 -path "*/cpython-$PYTHON_VERSION.*-linux-x86_64-gnu/bin/python$PYTHON_VERSION" | sort | head -1)
test -x "$PY"
uv venv --python "$PY" "$VENV"

# ---------------------------------------------------------------------------------------------
# 4. Python packages: hashed lock, binary wheels only, then strands-decider last.
# ---------------------------------------------------------------------------------------------
phase "packages from requirements.lock (--require-hashes --only-binary :all:)"
install -m 0644 "$BUNDLE/requirements.lock" "$OPT/requirements.lock"
uv pip install --python "$VENV/bin/python" --require-hashes --only-binary :all: --no-deps \
  --index-url "$PYPI_INDEX" --extra-index-url "$TORCH_INDEX" --index-strategy unsafe-best-match \
  -r "$OPT/requirements.lock"

phase "strands-decider ${DECIDER_COMMIT:0:7} (git, --no-deps)"
# The commit hash pins the source. The build uses the hashed setuptools, setuptools-scm and
# wheel from the lock (--no-build-isolation). Thus the build downloads nothing more.
uv pip install --python "$VENV/bin/python" --no-deps --no-build-isolation \
  "strands-decider @ git+${DECIDER_GIT}@${DECIDER_COMMIT}"
uv pip check --python "$VENV/bin/python"
uv pip freeze --python "$VENV/bin/python" > "$OPT/installed.txt"
"$VENV/bin/python" -c 'import torch; print("torch", torch.__version__, "cuda", torch.version.cuda, "gpu", torch.cuda.get_device_name(0), "bf16", torch.cuda.is_bf16_supported())' | tee -a "$PHASES"

# ---------------------------------------------------------------------------------------------
# 5. Model files at the pinned revisions, then the SHA-256 manifest check.
# ---------------------------------------------------------------------------------------------
phase "model download"
runuser -u decider -- env HF_HOME="$STATE/hf" HF_HUB_DISABLE_TELEMETRY=1 "$VENV/bin/python" - << PY
from huggingface_hub import snapshot_download
snapshot_download("${V19_REPO}", revision="${V19_REVISION}", local_dir="${STATE}/models/v19")
snapshot_download("${BASE_REPO}", revision="${BASE_REVISION}")
PY
ln -sfn "$STATE/hf/hub/models--${BASE_REPO/\//--}/snapshots/$BASE_REVISION" "$STATE/models/base"
phase "model manifest check (models.sha256)"
install -m 0644 "$BUNDLE/models.sha256" "$OPT/models.sha256"
(cd "$STATE/models" && grep -v '^#' "$OPT/models.sha256" | sha256sum --strict --quiet -c -)
phase "model manifest: $(grep -vc '^#' "$OPT/models.sha256") files pass"
# v19/MANIFEST.sha256 is now known. hf_export verify checks all other v19 files against it.
runuser -u decider -- env HF_HOME="$STATE/hf" HF_HUB_OFFLINE=1 "$VENV/bin/python" -m strands_decider.hf_export verify "$STATE/models/v19"
phase "hf_export verify: pass"

# ---------------------------------------------------------------------------------------------
# 6. decider-serve and decider.service
# ---------------------------------------------------------------------------------------------
phase "decider.service"
install -m 0755 "$BUNDLE/decider-serve" "$OPT/bin/decider-serve"
cat > /etc/decider/serve.env << ENV
DECIDER_MODEL_NAME=$MODEL_NAME
DECIDER_V19_REVISION=$V19_REVISION
DECIDER_BASE_REVISION=$BASE_REVISION
ENV
install -m 0644 "$BUNDLE/systemd/decider.service" /etc/systemd/system/decider.service
uv cache clean > /dev/null 2>&1 || true
date -u +%FT%TZ > "$STATE/INSTALLED"
systemctl daemon-reload
systemctl enable decider.service
phase "start decider.service (identity checks and warm-up)"
# Type=notify: this command returns when the service sends READY=1, after the warm-up.
systemctl start decider.service
phase "ready $(curl -fsS http://127.0.0.1:8000/ready | head -c 400)"
phase "disk $(df -h / | tail -n 1)"
phase "install complete"
