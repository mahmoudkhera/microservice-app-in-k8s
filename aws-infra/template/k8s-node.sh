#!/usr/bin/env bash
#
# setup-k8s-worker.sh
# Installs containerd and joins an Ubuntu node to a Kubernetes cluster.
#
# Usage:  sudo ./setup-k8s-worker.sh
#
# Notes:
#   - Tested target: Ubuntu 22.04 (jammy) / 24.04 (noble).
#   - This script prepares the node AND runs `kubeadm join` using a join command
#     fetched from SSM Parameter Store (/k8s/join-command).
#   - Run as root (or via sudo). Re-running is safe (idempotent).

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

K8S_MINOR="1.33"

apt-get update -y
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  unzip

mkdir -p /etc/apt/keyrings

# Remove any stale Docker repo entries from previous runs.
rm -f /etc/apt/sources.list.d/docker.list
sed -i '/download\.docker\.com/d' /etc/apt/sources.list 2>/dev/null || true

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Detect the Ubuntu codename.
UBUNTU_CODENAME=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    UBUNTU_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
fi
if [ -z "$UBUNTU_CODENAME" ]; then
    UBUNTU_CODENAME="$(lsb_release -cs)"
fi

# Docker only publishes for LTS releases; fall back to the newest supported one.
SUPPORTED_CODENAMES="focal jammy noble"
if ! echo "$SUPPORTED_CODENAMES" | grep -qw "$UBUNTU_CODENAME"; then
    UBUNTU_CODENAME="noble"
fi

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y containerd.io

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
systemctl enable containerd
systemctl restart containerd

swapoff -a || true
# Persist across reboots by commenting out swap lines in /etc/fstab
sed -i '/\bswap\b/s/^/#/' /etc/fstab

curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
    | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

containerd  --version        || true
kubeadm     version -o short || true
kubelet     --version        || true
kubectl     version --client --output=yaml || true

# Install AWS CLI v2
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" \
    -o "/tmp/awscliv2.zip"

unzip -qo /tmp/awscliv2.zip -d /tmp

/tmp/aws/install --update >/dev/null 2>&1

# Region from instance metadata (IMDSv2)
TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)
export AWS_DEFAULT_REGION="$REGION"

echo "Waiting for IAM role credentials..."
for i in {1..30}; do
  aws sts get-caller-identity >/dev/null 2>&1 && break
  echo "Waiting for credentials... attempt $i"
  sleep 5
done

# Already joined (reboot / re-run): nothing left to do.
if [ -f /etc/kubernetes/kubelet.conf ]; then
  echo "Node already joined, skipping."
  exit 0
fi

JOIN_CMD=""
for i in {1..20}; do
  JOIN_CMD=$(aws ssm get-parameter \
    --name "/k8s/join-command" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text 2>/dev/null) || JOIN_CMD=""

  if [ -n "$JOIN_CMD" ] && [ "$JOIN_CMD" != "placeholder" ]; then
    break
  fi
  echo "Join command not ready yet (attempt $i)..."
  sleep 30
done

if [ -z "$JOIN_CMD" ] || [ "$JOIN_CMD" = "placeholder" ]; then
  echo "ERROR: Never got join command from SSM" >&2
  exit 1
fi

# Wait until master is actually serving cluster-info, not just /healthz
MASTER_EP=$(echo "$JOIN_CMD" | awk '{print $3}')
echo "Probing master cluster-info at $MASTER_EP"
MASTER_READY=0
for i in {1..120}; do
  if curl -k --max-time 3 --silent --fail \
       "https://$MASTER_EP/api/v1/namespaces/kube-public/configmaps/cluster-info" \
       >/dev/null 2>&1; then
    echo "Master cluster-info reachable, joining"
    MASTER_READY=1
    break
  fi
  echo "Master not ready yet (attempt $i / 120)"
  sleep 5
done

if [ "$MASTER_READY" -ne 1 ]; then
  echo "ERROR: Master never became reachable at $MASTER_EP" >&2
  exit 1
fi

cat >/usr/local/bin/k8s-join.sh <<EOF
#!/bin/bash
set -e
# Skip if already joined (unit re-runs on every boot)
[ -f /etc/kubernetes/kubelet.conf ] && exit 0
$JOIN_CMD
EOF

chmod 700 /usr/local/bin/k8s-join.sh

cat >/etc/systemd/system/k8s-join.service <<EOF
[Unit]
Description=Kubernetes Worker Join
After=network-online.target containerd.service kubelet.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/k8s-join.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable k8s-join
systemctl start k8s-join