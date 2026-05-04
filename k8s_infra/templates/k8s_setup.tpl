#!/usr/bin/env bash
#
# setup-k8s.sh
# Installs Docker + containerd and prepares an Ubuntu node for Kubernetes (v1.30).
#
# Usage:  sudo ./setup-k8s.sh
#
# Notes:
#   - Tested target: Ubuntu 22.04 (jammy) / 24.04 (noble) / 25.04 (resolute).
#   - This script ONLY prepares the node. It does NOT run `kubeadm init` or `kubeadm join`.
#   - Run as root (or via sudo). Re-running is safe (idempotent).

set -euo pipefail


apt-get update -y
apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  software-properties-common


# Remove any stale Docker repo entries from previous runs.
# A missing keyring file + leftover sources entry causes "NO_PUBKEY" errors.
rm -f /etc/apt/sources.list.d/docker.list
sed -i '/download\.docker\.com/d' /etc/apt/sources.list 2>/dev/null || true

mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Detect the Ubuntu codename robustly across 20.04-25.04.
# /etc/os-release may expose VERSION_CODENAME or UBUNTU_CODENAME (24.04+).
UBUNTU_CODENAME=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    UBUNTU_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
fi
# Final fallback: lsb_release
if [ -z "$UBUNTU_CODENAME" ]; then
    UBUNTU_CODENAME="$(lsb_release -cs)"
fi

# Docker does not yet publish packages for every Ubuntu release (e.g. resolute/25.04).
# In that case, fall back to the latest LTS that Docker supports (noble/24.04).
SUPPORTED_CODENAMES="focal jammy noble"
if ! echo "$SUPPORTED_CODENAMES" | grep -qw "$UBUNTU_CODENAME"; then
    UBUNTU_CODENAME="noble"
fi

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io

systemctl start docker
systemctl enable docker
usermod -aG docker ubuntu

modprobe overlay
modprobe br_netfilter

cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system >/dev/null

mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml >/dev/null
# SystemdCgroup must be true on systemd hosts, otherwise kubelet will crashloop.
sed -i 's/^\(\s*SystemdCgroup\s*=\s*\)false/\1true/' /etc/containerd/config.toml
systemctl restart containerd

swapoff -a || true
# Persist across reboots by commenting out swap lines in /etc/fstab
sed -i '/\bswap\b/s/^/#/' /etc/fstab

mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

docker      --version        || true
containerd  --version        || true
kubeadm     version -o short || true
kubelet     --version        || true
kubectl     version --client --output=yaml || true

