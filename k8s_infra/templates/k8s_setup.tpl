#!/usr/bin/env bash
#
# setup-k8s.sh
# Installs Docker + containerd, initializes a Kubernetes (v1.30) control plane,
# and installs flannel, ingress-nginx, and ArgoCD.
#
# Usage:  sudo ./setup-k8s.sh
#
# Notes:
#   - Tested target: Ubuntu 22.04 (jammy) / 24.04 (noble) / 25.04 (resolute).
#   - This script prepares the node AND runs `kubeadm init`. It also publishes
#     the worker join command to SSM Parameter Store (/k8s/join-command).
#   - Run as root (or via sudo). Node-prep steps are idempotent; cluster-init
#     steps are not (re-running requires `kubeadm reset -f` first).

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
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash


docker      --version        || true
containerd  --version        || true
kubeadm     version -o short || true
kubelet     --version        || true
kubectl     version --client --output=yaml || true
helm version  || true


TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

# Init cluster
kubeadm init \
    --pod-network-cidr=10.244.0.0/16 \
    --apiserver-advertise-address="$PRIVATE_IP"


export KUBECONFIG=/etc/kubernetes/admin.conf
until kubectl get --raw=/healthz >/dev/null 2>&1; do
  echo "Waiting for API server..."
  sleep 3
done


USER_HOME="/home/ubuntu"
mkdir -p "$USER_HOME/.kube"
cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
chown ubuntu:ubuntu "$USER_HOME/.kube/config"


# Install AWS CLI v2
apt-get update -y
apt-get install -y unzip

curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
    -o "/tmp/awscliv2.zip" >/dev/null 2>&1

unzip -q /tmp/awscliv2.zip -d /tmp >/dev/null 2>&1

/tmp/aws/install >/dev/null 2>&1



echo "Waiting for IAM role credentials..."

for i in {1..30}; do
  aws sts get-caller-identity >/dev/null 2>&1 && break
  echo "Waiting for credentials... attempt $i"
  sleep 5
done

# ── Store join command in SSM ──
JOIN_CMD=$(kubeadm token create --print-join-command)
aws ssm put-parameter \
    --name "/k8s/join-command" \
    --value "$JOIN_CMD" \
    --type "String" \
    --overwrite \
    --region eu-west-1




kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

echo "Waiting for nodes to be ready"
EXPECTED_NODES=2  
while true; do
    READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"'| wc -l )
    TOTAL_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)

    echo "$(date) - Ready: $READY_COUNT / Expected: $EXPECTED_NODES (total seen: $TOTAL_COUNT)"

    if [ "$READY_COUNT" -ge "$EXPECTED_NODES" ]; then
        echo "$(date) - All expected nodes are Ready"
        break
    fi
    sleep 10
done

# Add the bitnami-labs repo
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets

# Update repos
helm repo update

# Verify repo added
helm repo list



helm repo add argo https://argoproj.github.io/argo-helm
helm repo update


kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/baremetal/deploy.yaml


kubectl patch svc ingress-nginx-controller -n ingress-nginx --type='json' -p='[
  {"op":"replace","path":"/spec/ports/0/nodePort","value":30080},
  {"op":"replace","path":"/spec/ports/1/nodePort","value":30443}
]'


kubectl create namespace argocd
helm install argocd argo/argo-cd \
  --namespace argocd

kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{
  "data": {
    "server.insecure": "true",
    "server.rootpath": "/argocd"
  }
}'

kubectl -n argocd rollout restart deployment argocd-server

mkdir -p /app

cat <<EOF > /app/argocd-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /argocd
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF


while true; do
    READY=$(kubectl get deployment "argocd-server" \
      -n "argocd" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

    DESIRED=$(kubectl get deployment "argocd-server" \
      -n "argocd" \
      -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")

    if [[ "$READY" == "$DESIRED" && "$READY" != "0" ]]; then
        echo "ArgoCD server is RUNNING"
        break
    fi

    echo "Still waiting... Ready: $READY / $DESIRED"
    sleep 5
done

kubectl apply -f /app/argocd-ingress.yaml

 aws secretsmanager get-secret-value \
      --secret-id my-yaml-secret \
      --region eu-west-1 \
      --query SecretString \
      --output text > /app/sealed-secrets-key.yaml

kubectl apply -f /app/sealed-secrets-key.yaml

sleep 10

# Add the sealed-secrets helm repo
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets

# Update repos
helm repo update

# Install sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system






echo "ArgoCD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d || echo "(could not read secret — fetch manually later)"
echo