#!/usr/bin/env bash

# setup-k8s.sh
# Installs containerd, initializes a Kubernetes control plane,
# and installs flannel, ingress-nginx, and ArgoCD.
#
# Usage:  sudo ./setup-k8s.sh
#
# Notes:
#   - Tested target: Ubuntu 22.04 (jammy) / 24.04 (noble).
#   - This script prepares the node AND runs `kubeadm init`. It also publishes
#     the worker join command to SSM Parameter Store (/k8s/join-command).
#   - Run as root (or via sudo). Node-prep steps are idempotent; cluster-init
#     steps are not (re-running requires `kubeadm reset -f` first).

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

K8S_MINOR="1.33"
EXPECTED_NODES=2

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

curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

containerd  --version        || true
kubeadm     version -o short || true
kubelet     --version        || true
kubectl     version --client --output=yaml || true
helm version  || true


TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

PRIVATE_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)
export AWS_DEFAULT_REGION="$REGION"

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
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" \
    -o "/tmp/awscliv2.zip"

unzip -qo /tmp/awscliv2.zip -d /tmp

/tmp/aws/install --update >/dev/null 2>&1


echo "Waiting for IAM role credentials..."

for i in {1..30}; do
  aws sts get-caller-identity >/dev/null 2>&1 && break
  echo "Waiting for credentials... attempt $i"
  sleep 5
done

# store join command in SSM 
JOIN_CMD=$(kubeadm token create --print-join-command)
aws ssm put-parameter \
    --name "/k8s/join-command" \
    --value "$JOIN_CMD" \
    --type "String" \
    --overwrite


kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

echo "Waiting for nodes to be ready"
DEADLINE=$(( $(date +%s) + 900 ))
while true; do
    READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready/' | wc -l)
    TOTAL_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)

    echo "$(date) - Ready: $READY_COUNT / Expected: $EXPECTED_NODES (total seen: $TOTAL_COUNT)"

    if [ "$READY_COUNT" -ge "$EXPECTED_NODES" ]; then
        echo "$(date) - All expected nodes are Ready"
        break
    fi
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
        echo "Timed out waiting for nodes"
        exit 1
    fi
    sleep 4
done

helm repo add ingress-nginx  https://kubernetes.github.io/ingress-nginx
helm repo add argo           https://argoproj.github.io/argo-helm
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets
helm repo update


helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443 \
  --wait --timeout 10m


helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --set configs.params."server\.insecure"=true \
  --set configs.params."server\.rootpath"=/argocd \
  --wait --timeout 10m

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

kubectl apply -f /app/argocd-ingress.yaml

aws secretsmanager get-secret-value \
      --secret-id my-yaml-secret \
      --query SecretString \
      --output text > /app/sealed-secrets-key.yaml

kubectl apply -f /app/sealed-secrets-key.yaml

helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  -n kube-system \
  --wait --timeout 5m


echo "ArgoCD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d || echo "(could not read secret — fetch manually later)"
echo