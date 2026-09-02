# Microservices-based inventory management system deployed in K8s from scratch
 
A microservices-based **inventory management system** with real-time low-stock email alerts. The application is built as three independent services that talk over HTTP, packaged as Docker images, deployed to Kubernetes via Helm, and shipped through a GitHub Actions CI pipeline that detects what changed and only rebuilds what's needed.
 



# k8s_infra — Terraform Infrastructure for Self-Managed Kubernetes on AWS

This directory provisions a production-style **self-managed Kubernetes cluster** on AWS using Terraform and bootstraps it with `cloud-init` user-data scripts. The cluster is built from scratch using `kubeadm` (no EKS), wired up with a NAT instance for cost efficiency, fronted by an Application Load Balancer, and pre-installed with Flannel (CNI), NGINX Ingress, ArgoCD (GitOps), and Sealed Secrets.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Network Topology](#network-topology)
- [Directory Layout](#directory-layout)
- [Modules](#modules)
- [Bootstrap Templates](#bootstrap-templates)
- [Variables](#variables)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [Post-Deployment](#post-deployment)
- [Cleanup](#cleanup)
- [Notes & Caveats](#notes--caveats)

---

## Architecture Overview

The Terraform code in this folder provisions the following on AWS (region `eu-west-1` by default):

| Component | Purpose |
|---|---|
| **VPC** (`192.168.0.0/16`) | Isolated network for the cluster |
| **2 Public subnets** | Host the public-facing Application Load Balancer |
| **2 Private subnets** | Host the Kubernetes control-plane and worker nodes |
| **1 Bastion subnet** | Public subnet hosting the bastion host (SSH jumpbox) |
| **Internet Gateway** | Egress for public subnets |
| **NAT instance (fck-nat)** | Cost-effective egress for private subnets (ARM `t4g.nano`) |
| **Bastion host** | `t2.nano` jumpbox in the public bastion subnet |
| **Master node** | `t2.medium` Kubernetes control-plane (private subnet) |
| **Worker node** | `t2.medium` Kubernetes worker (private subnet) |
| **Application Load Balancer** | Public-facing ALB forwarding to NodePort `30080` |
| **Security Groups** | Tiered SGs for ALB, bastion, private nodes, and NAT |
| **IAM Role + Instance Profile** | Grants nodes access to SSM and Secrets Manager |
| **SSM Parameter** (`/k8s/join-command`) | Channel to publish the `kubeadm join` command from master to workers |
| **Secrets Manager secret** | Holds the Sealed Secrets controller key (`sealed-secrets-key.yaml`) |

---

**Traffic flow:**
- **External users** → ALB (port 80) → NodePort `30080` on worker node → NGINX Ingress → Service → Pod.
- **Operator** → Bastion (SSH) → Private nodes (SSH).
- **Private nodes outbound** → NAT instance → Internet Gateway.



---

## Modules

### `modules/vpc`
Creates the VPC, the Internet Gateway, two public subnets, two private subnets, and a dedicated bastion subnet. All subnets are spread across two availability zones (`eu-west-1a`, `eu-west-1b`).

**Outputs:** `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `bastion_subnet_id`, `igw_id`.

### `modules/security`
Defines four security groups, each with the minimum required openings:

| SG | Ingress | Egress |
|---|---|---|
| `alb-sg` | All from `0.0.0.0/0` | All to private subnets |
| `bastion-sg` | TCP 22 from `0.0.0.0/0` | All to private subnets |
| `private-sg` | All TCP from ALB SG, all from private subnets, TCP 22 from allowed CIDRs | All to `0.0.0.0/0` |
| `nat-sg` | All from private subnets | All to `0.0.0.0/0` |

> **Tip:** the bastion SG opens port 22 to the world. Tighten `allowed_ssh_cidr_blocks` and the bastion ingress rule for any non-dev environment.

### `modules/ec2`
A generic, reusable instance module used three times in the root for the bastion, master, and worker. Highlights:

- Picks the latest **Ubuntu 24.04 (Noble) HVM SSD-gp3** AMI from Canonical.
- 30 GB encrypted `gp3` root volume (3000 IOPS, 125 MB/s).
- Optional `user_data` template, optional public IP, optional EIP, optional IAM instance profile.
- `lifecycle { ignore_changes = [ami] }` prevents AMI drift from triggering rebuilds.

### `modules/nat_instance`
Provisions a single **fck-nat** instance (community NAT AMI) on a `t4g.nano` ARM instance with `source_dest_check = false` and an attached EIP. The ENI ID is exported so the private route table can route `0.0.0.0/0` through it.

> Cheaper than a managed NAT Gateway (~$3/mo vs ~$32/mo) — appropriate for dev/lab environments. Not HA: if the NAT instance goes down, all egress from private subnets stops.

### `modules/route_table`
A single reusable module that creates either a public or private route table, depending on `is_public`:

- `is_public = true`  → adds a `0.0.0.0/0` route via the Internet Gateway.
- `is_public = false` → adds a `0.0.0.0/0` route via the NAT ENI (`network_interface_id`).

Subnet associations are built dynamically from `subnet_ids` using a `for_each` map.

### `modules/alb`
Creates an **internet-facing** Application Load Balancer, an HTTP listener on port 80, and a target group on port `30080` (the NGINX Ingress NodePort) with health checks against `/healthz`.

> Targets are not registered automatically — register the worker node(s) with the target group after deployment, or use an Auto Scaling Group attachment.

---

## Bootstrap Templates

The two `cloud-init` scripts in `templates/` do all the heavy lifting once Terraform has provisioned the EC2 instances. They are loaded by the EC2 module via `file(var.kubernetes_user_data)` and run as `root` on first boot, with their full output streamed to `/var/log/cloud-init-output.log` (the first place to look when debugging).

Both scripts share the same opening prep stage — that section is documented once below, then the master and worker diverge.

### Shared prep stage (runs on master and worker)

This is the first ~110 lines of both `k8s_setup.tpl` and `k8s_node.tpl`. Its job is to take a fresh Ubuntu AMI and turn it into a kubeadm-ready node.

#### 1. `set -euo pipefail` — fail fast
Aborts the script on the first error, on any unset variable, and on any failure inside a pipeline. Without this, a silent failure (e.g. a bad apt repo) would let the script continue and produce a half-broken node.

#### 2. Install base apt packages
```bash
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common
```
These are the prerequisites for adding HTTPS apt repos (Docker and Kubernetes), verifying GPG signatures, and detecting the Ubuntu release codename.

#### 3. Add the Docker apt repository (cleanly)
```bash
rm -f /etc/apt/sources.list.d/docker.list
sed -i '/download\.docker\.com/d' /etc/apt/sources.list 2>/dev/null || true
```
Removes any stale Docker repo entries from previous runs. A leftover entry pointing at a missing GPG keyring file produces the dreaded `NO_PUBKEY` error — wiping these first makes the script idempotent across re-runs and AMI updates.

```bash
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
```
Imports Docker's signing key into the modern `/etc/apt/keyrings/` location (the old `apt-key add` is deprecated).

#### 4. Detect Ubuntu codename robustly
```bash
UBUNTU_CODENAME=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    UBUNTU_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
fi
if [ -z "$UBUNTU_CODENAME" ]; then
    UBUNTU_CODENAME="$(lsb_release -cs)"
fi

SUPPORTED_CODENAMES="focal jammy noble"
if ! echo "$SUPPORTED_CODENAMES" | grep -qw "$UBUNTU_CODENAME"; then
    UBUNTU_CODENAME="noble"
fi
```
Reads the codename from `/etc/os-release` (preferred), falls back to `lsb_release`. **Crucial detail:** Docker doesn't publish packages for every Ubuntu release — for example, 25.04 (`resolute`) wasn't supported at the time these scripts were written. If the running release isn't in `focal/jammy/noble`, the script falls back to `noble` (24.04 LTS) so the apt repo URL still resolves to a real, working Docker package set.

#### 5. Install Docker + containerd
```bash
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl start docker
systemctl enable docker
usermod -aG docker ubuntu
```
Adds the Docker repo, installs `containerd` (the actual runtime kubelet talks to), enables Docker on boot, and adds the default `ubuntu` user to the `docker` group so you don't need `sudo docker` once SSH'd in.

#### 6. Load kernel modules required by Kubernetes networking
```bash
modprobe overlay
modprobe br_netfilter

cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
```
- **`overlay`** — backs the overlayfs storage driver containerd uses for image layers.
- **`br_netfilter`** — lets iptables see traffic on Linux bridges, which is how `kube-proxy` enforces Service rules on pod-to-pod traffic crossing the CNI bridge.

Writing them to `/etc/modules-load.d/k8s.conf` makes them load on every reboot.

#### 7. Enable required sysctls
```bash
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null
```
- The two `bridge-nf-call-*` keys make iptables rules apply to bridged traffic — required for `kube-proxy` to filter Service traffic correctly.
- `net.ipv4.ip_forward = 1` allows the node to forward packets between interfaces, which the CNI needs for pod-to-pod communication.

`sysctl --system` reloads everything from `/etc/sysctl.d/` so the values take effect immediately and persist across reboots.

#### 8. Configure containerd to use systemd cgroups
```bash
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml >/dev/null
sed -i 's/^\(\s*SystemdCgroup\s*=\s*\)false/\1true/' /etc/containerd/config.toml
systemctl restart containerd
```
Generates a default containerd config and flips `SystemdCgroup` from `false` to `true`. This is **non-negotiable on systemd-based hosts** (which Ubuntu is): if the kubelet uses the systemd cgroup driver but containerd uses cgroupfs, the kubelet will crashloop with cgroup-mismatch errors.

#### 9. Disable swap
```bash
swapoff -a || true
sed -i '/\bswap\b/s/^/#/' /etc/fstab
```
Kubernetes refuses to start kubelet if swap is on (it interferes with the scheduler's memory accounting). `swapoff -a` disables it now; the `sed` comments out swap entries in `/etc/fstab` so it stays off after reboots.

#### 10. Install kubelet, kubeadm, kubectl (v1.30)
```bash
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
```
Adds the official Kubernetes apt repo (pinned to the **v1.30** stream), installs the three core binaries, and `apt-mark hold`s them so a routine `apt upgrade` can't silently bump them to a version your cluster isn't ready for.

> Note: `systemctl enable --now kubelet` starts kubelet immediately, but it will crashloop until `kubeadm init` (master) or `kubeadm join` (worker) gives it a config to work with. That's expected — don't be alarmed by red `kubelet` status until the next stage finishes.

#### 11. Install AWS CLI v2 and wait for IAM credentials
```bash
apt-get install -y unzip
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

for i in {1..30}; do
  aws sts get-caller-identity >/dev/null 2>&1 && break
  echo "Waiting for credentials... attempt $i"
  sleep 5
done
```
Installs the AWS CLI v2 (Ubuntu's package repo only ships v1, which is end-of-life) and then polls `sts get-caller-identity` until the EC2 instance's IAM role credentials are actually retrievable. There's a small race on instance launch where the IAM role is attached but the metadata service hasn't published credentials yet — this loop hides that race.

The IAM role itself (`ec2-k8s-role`, defined in `main.tf`) gives both nodes:
- `AmazonSSMFullAccess` — for the SSM Parameter Store handshake (`/k8s/join-command`).
- A custom inline policy granting `secretsmanager:GetSecretValue` and `secretsmanager:DescribeSecret` on the Sealed Secrets key — only the master actually uses this.

---

After the shared prep finishes, the two scripts diverge.

### `templates/k8s_setup.tpl` — Master node

The master script picks up where the shared prep left off and turns the prepped node into a fully working control plane with GitOps + secrets management already installed.

#### M1. Install Helm
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```
The master uses Helm to install ArgoCD and Sealed Secrets later in the script.

#### M2. Initialize the control plane
```bash
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

kubeadm init \
    --pod-network-cidr=10.244.0.0/16 \
    --apiserver-advertise-address="$PRIVATE_IP"
```
- Fetches an **IMDSv2** token first (instance metadata service v2 requires this — IMDSv1 is disabled on modern AMIs), then queries for the local IPv4.
- Calls `kubeadm init` with:
  - `--pod-network-cidr=10.244.0.0/16` — the default Flannel pod CIDR. Must match what Flannel expects, otherwise pod networking silently breaks.
  - `--apiserver-advertise-address` — pinned to the instance's private IP so kubelet knows exactly which interface the API server is reachable on. Important on multi-NIC AWS instances.

#### M3. Wait for the API server, then publish kubeconfig
```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
until kubectl get --raw=/healthz >/dev/null 2>&1; do
  echo "Waiting for API server..."
  sleep 3
done

USER_HOME="/home/ubuntu"
mkdir -p "$USER_HOME/.kube"
cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
chown ubuntu:ubuntu "$USER_HOME/.kube/config"
```
Loops on `/healthz` until the API server actually responds — `kubeadm init` returns as soon as static pod manifests are written, which is *before* the API is serving. Then copies the admin kubeconfig to the `ubuntu` user's home with correct ownership so you can `kubectl` immediately after SSHing in.

#### M4. Publish the join command to SSM
```bash
JOIN_CMD=$(kubeadm token create --print-join-command)
aws ssm put-parameter \
    --name "/k8s/join-command" \
    --value "$JOIN_CMD" \
    --type "String" \
    --overwrite \
    --region eu-west-1
```
This is **the master-worker handshake.** Terraform pre-creates `/k8s/join-command` with value `"placeholder"`. The master overwrites it here with the real command (which contains the API endpoint, bootstrap token, and CA cert hash). The worker script polls this same parameter until it's no longer `"placeholder"`, then runs it.

`--overwrite` is required because the parameter already exists from Terraform.

#### M5. Install Flannel (CNI)
```bash
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
```
Without a CNI, every node stays `NotReady` (kubelet refuses to mark a node ready until pod networking exists). Flannel is chosen here for simplicity — it just works with the `10.244.0.0/16` CIDR set during `kubeadm init`.

#### M6. Wait for all nodes to be Ready
```bash
EXPECTED_NODES=2
while true; do
    READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
    TOTAL_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    echo "$(date) - Ready: $READY_COUNT / Expected: $EXPECTED_NODES (total seen: $TOTAL_COUNT)"
    if [ "$READY_COUNT" -ge "$EXPECTED_NODES" ]; then
        echo "$(date) - All expected nodes are Ready"
        break
    fi
    sleep 10
done
```
Blocks until the worker has joined and gone Ready. **`EXPECTED_NODES=2` is hard-coded** — if you scale up, change this constant or the master will block forever.

#### M7. Add Helm repos
```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

#### M8. Install NGINX Ingress and patch NodePorts
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/baremetal/deploy.yaml

kubectl patch svc ingress-nginx-controller -n ingress-nginx --type='json' -p='[
  {"op":"replace","path":"/spec/ports/0/nodePort","value":30080},
  {"op":"replace","path":"/spec/ports/1/nodePort","value":30443}
]'
```
Uses the **bare-metal** manifest (not the AWS one) because we want a NodePort Service that the public ALB can target — not a separate cloud-provider load balancer per Ingress. The patch pins the NodePorts to **30080 (HTTP) and 30443 (HTTPS)**, which matches the ALB target group's port (`30080`) configured in the `alb` module.

#### M9. Install ArgoCD with a sub-path ingress
```bash
kubectl create namespace argocd
helm install argocd argo/argo-cd --namespace argocd

kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{
  "data": {
    "server.insecure": "true",
    "server.rootpath": "/argocd"
  }
}'
kubectl -n argocd rollout restart deployment argocd-server
```
- `server.insecure: true` — disables ArgoCD's own TLS so it speaks plain HTTP. TLS termination happens at the ALB instead.
- `server.rootpath: /argocd` — makes ArgoCD serve under the `/argocd` URL prefix instead of `/`, so the same ALB can later host other apps at other paths.
- The deployment is restarted for the new config to take effect.

Then an Ingress is generated and applied:
```yaml
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
```
Before applying, the script polls until the `argocd-server` deployment has `readyReplicas == replicas` (and not zero) so the Ingress doesn't 502 on first hit.

#### M10. Restore the Sealed Secrets controller key from AWS Secrets Manager
```bash
aws secretsmanager get-secret-value \
      --secret-id my-yaml-secret \
      --region eu-west-1 \
      --query SecretString \
      --output text > /app/sealed-secrets-key.yaml

kubectl apply -f /app/sealed-secrets-key.yaml
```
This is what makes Sealed Secrets actually useful across redeploys. The flow is:
1. You generated a Sealed Secrets controller key once locally (the file `sealed-secrets-key.yaml` in this directory).
2. Terraform uploaded that file's contents into AWS Secrets Manager (`my-yaml-secret`).
3. The master pulls it back here and applies it to the cluster **before** installing the controller.
4. When the controller starts, it sees an existing key and uses it instead of generating a new random one.

Result: every `kubeseal`'d YAML you produced against this key remains decryptable, even if you destroy the cluster and recreate it tomorrow.

#### M11. Install the Sealed Secrets controller
```bash
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system
```

#### M12. Print the ArgoCD initial admin password
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```
You'll find this at the very bottom of `/var/log/cloud-init-output.log` on the master.

---

### `templates/k8s_node.tpl` — Worker node

After the shared prep stage finishes, the worker has Docker, containerd, kubelet, kubeadm, kubectl, and AWS CLI installed but is **not yet a member of any cluster**. Its job from here is to fetch the join command the master published and run it — robustly enough to survive the master not being ready yet.

#### W1. Poll SSM until the master publishes the real join command
```bash
JOIN_CMD=""
for i in {1..20}; do
  JOIN_CMD=$(aws ssm get-parameter \
    --name "/k8s/join-command" \
    --query "Parameter.Value" \
    --output text \
    --region eu-west-1 2>/dev/null) || JOIN_CMD=""

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
```
Tries up to **20 times with 30-second sleeps** (so up to 10 minutes total). Two distinct failure modes are handled:
- **Empty string** — the SSM call itself failed (transient AWS API issue). The `|| JOIN_CMD=""` guards against the script aborting under `set -e`.
- **Literal `"placeholder"`** — the SSM parameter exists (Terraform created it) but the master hasn't overwritten it yet.

Only when `JOIN_CMD` is both non-empty *and* not `"placeholder"` does the loop break. If 10 minutes pass without success, the script hard-exits with an error.

#### W2. Wait for the master's API server to actually serve cluster-info
```bash
MASTER_EP=$(echo "$JOIN_CMD" | awk '{print $3}')
echo "Probing master cluster-info at $MASTER_EP..."
for i in {1..120}; do
  if curl -k --max-time 3 --silent --fail \
       "https://$MASTER_EP/api/v1/namespaces/kube-public/configmaps/cluster-info" \
       >/dev/null 2>&1; then
    echo "Master cluster-info reachable, joining..."
    break
  fi
  echo "Master not ready yet (attempt $i / 120)..."
  sleep 5
done
```
A `kubeadm join` command looks like:
```
kubeadm join 192.168.3.7:6443 --token abc.xyz --discovery-token-ca-cert-hash sha256:...
```
`awk '{print $3}'` extracts the third field — `192.168.3.7:6443` — which is the API endpoint.

The loop curls the `cluster-info` ConfigMap (which `kubeadm join` itself reads to discover the cluster). This is a stricter health check than `/healthz`: a master can answer `/healthz` while still booting kube-apiserver, but `cluster-info` only appears once kubeadm has fully written it. Probing it here avoids a race where the worker tries to join milliseconds before the master is ready and fails with a confusing CA-hash mismatch.

Up to **120 attempts × 5 seconds = 10 minutes** of patience. If it still isn't reachable, the loop just falls through (no hard exit) and the join attempt below will surface the real error.

#### W3. Wrap the join command in a systemd one-shot
```bash
cat >/usr/local/bin/k8s-join.sh <<EOF
#!/bin/bash
set -e
$JOIN_CMD
EOF
chmod +x /usr/local/bin/k8s-join.sh

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
```
Rather than running `kubeadm join` directly inside the cloud-init script, it's wrapped in a systemd unit. Why this matters:

- **`After=network-online.target containerd.service kubelet.service`** — guarantees the join only fires after the network is fully up and both containerd and kubelet are running. Cloud-init runs early in boot when these may not all be ready yet.
- **`Type=oneshot` + `RemainAfterExit=yes`** — runs once, marks itself "active" forever after success, so systemd doesn't try to re-run it on every boot. The actual idempotence comes from kubeadm itself: a node that's already joined will fail the second `kubeadm join`, which would mark the service failed on every reboot if not for this flag.
- **Recovery is straightforward** — if the join failed, `journalctl -u k8s-join` shows exactly why. To retry: `kubeadm reset -f && systemctl restart k8s-join`.



---

## Variables

Defined in `variable.tf`. All have defaults — override via a `terraform.tfvars` file or `-var` flags.

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `eu-west-1` | AWS region |
| `environment` | `dev` | Environment tag applied to all resources |
| `vpc_cidr` | `192.168.0.0/16` | VPC CIDR |
| `public_subnets` | `["192.168.1.0/24", "192.168.2.0/24"]` | Public subnet CIDRs |
| `private_subnets` | `["192.168.3.0/24", "192.168.4.0/24"]` | Private subnet CIDRs |
| `bastion_subnet` | `192.168.5.0/24` | Bastion subnet CIDR |
| `allowed_ssh_cidr_blocks` | `["192.168.5.0/24"]` | CIDRs allowed to SSH into private nodes (default = bastion subnet only) |
| `availability_zones` | `["eu-west-1a", "eu-west-1b"]` | AZs for subnets |
| `instance_type` | `t2.nano` | Default instance type (overridden per-instance in `main.tf`) |
| `key_name` | `ec2-key` | SSH key pair name (must already exist in the region) |
| `kubernetes_master_user_data` | `./templates/k8s_setup.tpl` | Path to master bootstrap script |
| `kubernetes_node_user_data` | `./templates/k8s_node.tpl` | Path to worker bootstrap script |

---

## Prerequisites

Before running `terraform apply`:

1. **Terraform** ≥ 1.5 and the **AWS provider** v6.x.
2. **AWS credentials** configured (`aws configure`, `AWS_PROFILE`, or instance role) with permissions to create VPCs, EC2, IAM, ALB, SSM, and Secrets Manager resources.
3. An existing **EC2 key pair** in `eu-west-1` whose name matches `var.key_name` (default `ec2-key`).
4. The file **`sealed-secrets-key.yaml`** must exist in this directory. It is loaded into AWS Secrets Manager and applied to the cluster so Sealed Secrets created locally with `kubeseal` against the same key remain decryptable. Generate or restore yours before applying.

---

## Usage

```bash
cd k8s_infra

# 1. Initialize providers and modules
terraform init

# 2. Review the plan
terraform plan

# 3. Apply
terraform apply
```

Provisioning takes roughly **8–12 minutes**: ~2 minutes for AWS resources, then several more for the master to fully bootstrap, install Flannel/NGINX/ArgoCD/Sealed Secrets, and for the worker to join.

---

## Post-Deployment

### SSH in via the bastion
```bash
# Get IPs from the AWS console or `terraform state show ...`
ssh -i ~/.ssh/ec2-key.pem -J ubuntu@<bastion-public-ip> ubuntu@192.168.3.7   # master
ssh -i ~/.ssh/ec2-key.pem -J ubuntu@<bastion-public-ip> ubuntu@192.168.3.8   # worker
```

### Verify the cluster
On the master:
```bash
kubectl get nodes
kubectl get pods -A
```
Both nodes should show `Ready`. Flannel, NGINX Ingress, ArgoCD, and Sealed Secrets pods should all be `Running`.

### Access ArgoCD
1. Get the ALB DNS name from the AWS console (or `terraform output` if you add one).
2. **Register the worker node** with the ALB target group (`<env>-tg`) on port `30080`. This is currently a manual step — the Terraform code does not auto-attach instances.
3. Browse to `http://<alb-dns-name>/argocd`.
4. Username `admin`. Password is printed at the end of the master's `cloud-init-output.log` (`/var/log/cloud-init-output.log`), or fetch it directly:
   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath="{.data.password}" | base64 -d
   ```

### Sealing secrets locally
```bash
kubeseal --controller-namespace kube-system \
         --controller-name sealed-secrets \
         --format yaml < my-secret.yaml > my-sealed-secret.yaml
```

---

## Cleanup

```bash
terraform destroy
```

Note that **the Secrets Manager secret is configured with `recovery_window_in_days = 0`** — it is hard-deleted immediately. Save a copy of `sealed-secrets-key.yaml` somewhere safe before destroying if you need to keep decrypting old SealedSecrets later.

---

## The Services
 
### Frontend
 
**Location:** `frontend/`
**Stack:** Node.js 20 · Express · vanilla JavaScript
 
A tiny Express server with two responsibilities:
 
1. Serve `index.html` (a single-page dashboard, fully self-contained — no build step).
2. Expose `GET /config.js`, which returns a JavaScript snippet of the form
   ```js
   window.API = "http://...";
   ```
   The dashboard loads this script before its own code runs, so the browser learns the inventory service's URL **at runtime** instead of having it baked into the image at build time. This is what makes the same image work in local Docker Compose, in Kubernetes via Ingress, and behind the ALB without rebuilding.
**Environment variables**
 
| Variable | Default | Purpose |
|---|---|---|
| `FRONTEND_PORT` | `8000` | Port to listen on |
| `FRONTEND_HOST` | `0.0.0.0` | Bind address |
| `API` | `http://localhost:3000` | Inventory service URL surfaced to the browser via `/config.js` |
 
**Dockerfile** — multi-stage:
- **Stage 1** (`node:20-alpine`) installs npm dependencies.
- **Stage 2** (`gcr.io/distroless/nodejs20-debian12`) is the runtime — distroless, no shell, no package manager, just Node.js and the app. Smaller attack surface, smaller image.
### Inventory Service
 
**Location:** `inventory-service/`
**Stack:** Node.js 20 · Express · `pg` (PostgreSQL driver)
 
The only service that owns data. On startup it:
 
1. Reads `DATABASE_URL` and aborts immediately if it's missing.
2. Opens a `pg` connection pool.
3. Retries `SELECT 1` up to **10 times with 2-second backoff** while Postgres warms up.
4. Creates three tables if they don't exist: `products`, `alerts`, `config`.
5. Seeds the `config` table with a default alert email address.
**HTTP API**
 
| Method | Path | Description |
|---|---|---|
| `GET` | `/products` | List all products |
| `POST` | `/products` | Create a product `{ name, quantity, threshold? }` |
| `PATCH` | `/products/:id` | Update a product's quantity. **Triggers an alert if `quantity ≤ threshold`** |
| `DELETE` | `/products/:id` | Delete a product |
| `POST` | `/stock-check` | Manually scan all products and alert on any below threshold |
| `GET` | `/alerts` | Last 20 alerts (most recent first) |
| `DELETE` | `/alerts` | Clear alert history |
| `GET` | `/config/email` | Current alert recipient |
| `POST` | `/config/email` | Update alert recipient |
| `GET` | `/health` | Liveness probe — `{ status: "ok", service: "inventory" }` |
 
**Alert flow.** When a quantity drops to/below threshold, the service inserts a row into `alerts` (so we have a durable record even if the email send fails) and then **fires an HTTP POST to the notifications service**. If notifications is unreachable, the error is logged but the API call still succeeds — the alert exists in the database and the inventory operation isn't blocked.
 
**CORS.** A simple permissive middleware reads `CORS_ORIGIN` (default `*`) so the browser-side dashboard can call this service directly when the Ingress hostnames don't share an origin.
 
### Notifications Service
 
**Location:** `notifications-service/`
**Stack:** Python 3.12 · Flask · `smtplib` (stdlib) · gunicorn (4 workers in production)
 
A focused single-endpoint service that converts JSON requests into SMTP email sends.
 
**HTTP API**
 
| Method | Path | Description |
|---|---|---|
| `POST` | `/notify` | Body: `{ "to": "...", "subject": "...", "message": "..." }`. Returns 400 if `to` is missing. |
| `GET` | `/health` | Liveness probe with the SMTP config it sees |
 
**Why it has so much logging.** The service logs every step of the SMTP flow — TCP connect, TLS handshake, login, send — and catches each `smtplib` exception type separately (`SMTPAuthenticationError`, `SMTPConnectError`, `SMTPServerDisconnected`, `SMTPException`, `TimeoutError`). Authentication failures specifically print a hint reminding the operator that **Gmail requires a 16-character App Password, not the regular account password**. This is the most common deployment mistake by far, so the error message is loud about it.
 
**Validation at startup.** If `SMTP_USER` or `SMTP_PASSWORD` are missing, the service raises `SystemExit` immediately rather than starting up half-broken — `kubectl get pods` will show `CrashLoopBackOff` and the logs will say exactly which variable is missing.
 
**Dockerfile** — `python:3.12-alpine`, runs under `gunicorn` with 4 workers bound to `0.0.0.0:3002`.
 
---
 
## Running Locally with Docker Compose
 
The fastest way to bring everything up.
 
### Prerequisites
- Docker 20.10+
- Docker Compose v2
- A Gmail account with an [App Password](https://myaccount.google.com/apppasswords) for the alert sender
### Steps
 
```bash
# 1. Clone
git clone https://github.com/mahmoudkhera/microservice-app-in-k8s.git
cd microservice-app-in-k8s
 
# 2. Create a .env file (see the table in the next section)
cp .env.example .env   # if available; otherwise create one manually
$EDITOR .env
 
# 3. Bring it up
docker compose up --build
```
 
First-time build is around 2 minutes; subsequent runs use the layer cache and start in seconds.
 
Once running:
- Dashboard: <http://localhost:8000>
- Inventory API: <http://localhost:3000>
- Notifications API: <http://localhost:3002>
### Smoke test
 
Add a product with a quantity below its threshold and you should immediately receive an email alert:
 
```bash
curl -X POST http://localhost:3000/products \
  -H 'Content-Type: application/json' \
  -d '{"name":"USB-C Cable","quantity":3,"threshold":5}'
 
curl http://localhost:3000/alerts   # the alert row should appear here
```
 
> The `docker-compose.yaml` in the project root **does not include a Postgres service** — it expects an external `DATABASE_URL` (the project uses [Neon](https://neon.tech) as a hosted Postgres). If you'd rather run Postgres locally, add a `postgres:16` service to the compose file and point `DATABASE_URL` at it.
 
---
 
## Environment Variables
 
A `.env` file at the project root drives the local stack. The same names are also used by the Helm chart (via ConfigMaps and Secrets) and by the CI integration test.
 
```bash
# ─── Database ──────────────────────────────────────────
DATABASE_URL=postgresql://user:password@host:5432/stockwatch
 
# ─── Frontend ──────────────────────────────────────────
FRONTEND_PORT=8000
FRONTEND_HOST=0.0.0.0
API=http://localhost:3000     # The browser-facing inventory URL
 
# ─── Inventory Service ─────────────────────────────────
INVENTORY_PORT=3000
INVENTORY_HOST=0.0.0.0
CORS_ORIGIN=*
ALERT_RECIPIENT=admin@example.com
 
# ─── Notifications Service ─────────────────────────────
NOTIFICATION_PORT=3002
NOTIFICATION_HOST=0.0.0.0
 
# SMTP — Gmail example. Use an App Password, not your regular password.
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your-email@gmail.com
SMTP_PASSWORD=your-16-char-app-password
SMTP_FROM=your-email@gmail.com
```
 
> **Gmail setup.** Enable 2FA on your Google account, then generate an App Password at <https://myaccount.google.com/apppasswords>. The 16-character output is what goes in `SMTP_PASSWORD` — your regular password will not work and Google has officially deprecated "less secure app access".
 
---
 
## Deploying to Kubernetes (Helm Chart)
 
`helm_chart/` contains a single chart that deploys all three services along with their ConfigMaps, Secrets, Services, and an Ingress that routes by hostname.
 
### What the chart creates
 
| Resource | Notes |
|---|---|
| **Frontend Deployment** | 3 replicas. Image and tag come from `values.yaml`. Reads config from a ConfigMap. CPU `50m`–`100m`, memory `16Mi`–`128Mi`. |
| **Frontend Service** | ClusterIP by default, named port matches what the Ingress references. |
| **Frontend ConfigMap** | `FRONTEND_PORT`, `FRONTEND_HOST`, `API`. |
| **Inventory Deployment** | 2 replicas. Loads env from both a ConfigMap and a Secret. |
| **Inventory Service** | ClusterIP. |
| **Inventory ConfigMap** | `PORT`, `HOST`, `CORS_ORIGIN`, `ALERT_RECIPIENT`, `NOTIFICATION_URL`. |
| **Inventory Secret** | Holds `DATABASE_URL` (base64-encoded automatically via the Helm `b64enc` template function). |
| **Notifications Deployment** | 1 replica. ConfigMap + Secret. |
| **Notifications Service** | ClusterIP. |
| **Notifications ConfigMap** | `PORT`, `HOST`, `SMTP_PORT`, `SMTP_FROM`. |
| **Notifications Secret** | `SMTP_HOST`, `SMTP_USER`, `SMTP_PASSWORD`. |
| **Ingress** | Two hostname rules: one for the frontend, one for the inventory API. Both forward to the named service ports. Uses `ingressClassName: nginx`. |
 

 
## CI/CD Pipeline
 
The workflow lives at `.github/workflows/main.yml`. End-to-end, it does **change detection → vulnerability scanning → parallel builds → integration testing**, and is engineered so a one-line change to a single service doesn't trigger a rebuild of the other two. This section walks through every job in the order they execute and explains what each step is for and why.
 
### Triggers
 
```yaml
on:
  workflow_dispatch:
    inputs:
      frontend_tag:      { type: choice, options: [latest, commited] }
      inventory_tag:     { type: choice, options: [latest, commited] }
      notifications_tag: { type: choice, options: [latest, commited] }
  push:
    branches: [main]
    paths:
      - 'frontend/**'
      - 'inventory-service/**'
      - 'notifications-service/**'
  pull_request:
```
 
Three ways the pipeline kicks off:
 
1. **`push` to `main`** — but only if files under one of the three service directories changed. Pushing a docs-only change won't burn CI minutes. The `paths:` filter is a coarse gate at the trigger level; the `detect-changes` job below does the fine-grained per-service decisions.
2. **`pull_request`** — runs on every PR so reviewers see test results before merge.
3. **`workflow_dispatch`** — manual trigger from the Actions tab. Each service has its own dropdown letting you choose between `latest` (a stable rebuild) and `commited` (rebuild at the current commit SHA). This is the escape hatch for "rebuild everything against this commit even though nothing changed in those folders."
### Job 1 — `detect-changes`
 
```yaml
detect-changes:
  if: github.event_name == 'push'
  outputs:
    frontend:      ${{ steps.filter.outputs.frontend }}
    inventory:     ${{ steps.filter.outputs.inventory }}
    notifications: ${{ steps.filter.outputs.notifications }}
  steps:
    - uses: actions/checkout@v4
    - uses: dorny/paths-filter@v3
      id: filter
      with:
        filters: |
          frontend:      ['frontend/**']
          inventory:     ['inventory-service/**']
          notifications: ['notifications-service/**']
```
 
Uses [`dorny/paths-filter`](https://github.com/dorny/paths-filter) to compare the pushed commits against the previous state and set three boolean outputs — `frontend`, `inventory`, `notifications` — to `'true'` or `'false'` based on which directories actually changed. Every downstream job reads these flags to decide whether to run.
 
The job is gated to `push` events only (`if: github.event_name == 'push'`), which means **on a manual `workflow_dispatch` it doesn't run at all** — its outputs are empty. The downstream `if:` conditions are written so that the absence of a `detect-changes` result, combined with a manually-supplied tag input, also triggers a build. That's the dual-mode logic.
 
### Job 2 — `vulnerability-scanning` (matrix)
 
```yaml
vulnerability-scanning:
  needs: detect-changes
  strategy:
    matrix:
      service: [frontend, inventory-service, notifications-service]
  steps:
    - uses: actions/checkout@v4
    - name: Scan ${{ matrix.service }}
      if: |
        (matrix.service == 'frontend' && needs.detect-changes.outputs.frontend == 'true') ||
        (matrix.service == 'inventory-service' && needs.detect-changes.outputs.inventory == 'true') ||
        (matrix.service == 'notifications-service' && needs.detect-changes.outputs.notifications == 'true')
      uses: sonarsource/sonarqube-scan-action@master
      with:
        projectBaseDir: ${{ matrix.service }}
        args: >
          -Dsonar.organization=mahmoudkhera
          -Dsonar.projectKey=mahmoudkhera_${{ matrix.service }}
          -Dsonar.sources=.
          -Dsonar.host.url=https://sonarcloud.io
```
 
Spins up **three parallel jobs** (one per service) via a matrix strategy. Each job's *step* is conditional: it only runs SonarCloud if its specific service's `detect-changes` flag is `'true'`. So if only the inventory service changed, the matrix still creates three jobs but only the inventory job's scan step actually executes — the other two skip silently. This pattern keeps the dependency graph readable while avoiding wasted scan time.
 
Each service is registered as its own SonarCloud project (`mahmoudkhera_<service>`), so issue tracking, the quality-gate decision, and the security report stay scoped per service.
 
### Jobs 3, 4, 5 — `build-frontend`, `build-inventory`, `build-notifications`
 
The three build jobs are structurally identical; only the paths and image names differ. Walking through `build-frontend`:
 
```yaml
build-frontend:
  needs: [detect-changes, vulnerability-scanning]
  if: |
    !cancelled() && (
    (needs.detect-changes.result == 'success' && needs.detect-changes.outputs.frontend == 'true') ||
    github.event.inputs.frontend_tag != ''
    )
  outputs:
    tag: ${{ steps.set-tag.outputs.tag }}
```
 
**The `if:` is the key bit.** The build runs when *either*:
- `detect-changes` ran successfully **and** flagged this service as changed, **or**
- the workflow was manually dispatched **and** the user picked a tag for this service from the dropdown (`github.event.inputs.frontend_tag` is non-empty).
`!cancelled()` means "even if an upstream job was skipped, keep going as long as the workflow wasn't actually cancelled." Without this, the build would refuse to start when `detect-changes` was skipped on a manual dispatch.
 
#### Step-by-step
 
```yaml
- name: Determine image tag
  id: set-tag
  run: |
    if [ "${{ github.event.inputs.frontend_tag}}" = "latest" ]; then
      TAG="${{ github.event.inputs.frontend_tag }}"
    else
      TAG="${{ github.sha }}"
    fi
    echo "tag=$TAG" >> $GITHUB_OUTPUT
```
 
Decides the image tag. **Manual dispatch with `latest` selected** → tag is the literal string `latest`. **Anything else** (push to main, PR, or manual dispatch with `commited` selected) → tag is the full commit SHA. Push events trip the `else` branch because `github.event.inputs.frontend_tag` is empty on push, so they get SHA tags too.
 
```yaml
- uses: docker/login-action@v3
  with:
    username: ${{ secrets.DOCKER_USERNAME }}
    password: ${{ secrets.DOCKER_PASS }}
 
- uses: docker/setup-buildx-action@v3
```
 
Logs into Docker Hub and sets up Buildx (required for the registry-based build cache below).
 
```yaml
- name: Build and Push Image
  uses: docker/build-push-action@v5
  with:
    context: ./frontend
    push: true
    tags: ${{ secrets.DOCKER_USERNAME }}/devops2-frontend:${{ steps.set-tag.outputs.tag }}
    cache-from: type=registry,ref=${{ secrets.DOCKER_USERNAME }}/devops2-frontend:buildcache
```
 
Builds the image and pushes it. **`cache-from`** pulls a separate image (`...:buildcache`) and uses its layers as a cache source — so on the next run, unchanged layers (npm install, base image) are imported from Docker Hub instead of rebuilt from scratch. This is what keeps cold-runner builds under a minute.
 
> Worth noting: the workflow only specifies `cache-from`, not `cache-to`. The cache image only gets refreshed if you also push to it, which you'd do with `cache-to: type=registry,ref=...:buildcache,mode=max`. Without `cache-to`, the cache image only updates if someone pushes it manually. Easy improvement for a future PR.
 
```yaml
- name: Save SHA to cache
  run: echo "${{ steps.set-tag.outputs.tag }}" > frontend-sha.txt
 
- name: Cache frontend SHA
  uses: actions/cache/save@v4
  with:
    path: frontend-sha.txt
    key: frontend-last-sha
```
 
This is the **clever piece that makes single-service rebuilds work end-to-end.** After every successful build, the chosen tag is written to a tiny text file and stored in the GitHub Actions cache under a stable key (`frontend-last-sha`).
 
Why this matters: the integration test stage needs to spin up *all three* services together, but on this run we only built one of them. The integration test job restores these cache entries to learn what tag the *other two* were built with on their last successful run, and pulls those — so we always have a coherent set of three deployable images even when only one was rebuilt today.
 
The same `Save SHA → Cache SHA` pair appears in `build-inventory` (writing `inventory-sha.txt`) and `build-notifications` (writing `notifications-sha.txt`).
 
### Job 6 — `integration-test`
 
```yaml
integration-test:
  needs: [detect-changes, build-frontend, build-inventory, build-notifications]
  if: |
    always() &&
    !failure() &&
    (needs.build-frontend.result == 'success' ||
     needs.build-inventory.result == 'success' ||
     needs.build-notifications.result == 'success')
  environment: 'dev-env'
```
 
The condition reads as: "Run if at least one build succeeded **and** none of the dependencies actually failed (skipped is fine)." `always() && !failure()` is GitHub Actions idiom for "don't auto-skip me when an upstream is skipped, but do skip me if anything actually failed."
 
`environment: 'dev-env'` ties this job to a [GitHub Environment](https://docs.github.com/en/actions/deployment/targeting-different-environments) so its env-scoped secrets and variables (`DATABASE_URL`, `SMTP_*`, `ALERT_RECIPIENT`) come from there rather than the repo-level secret store.
 
#### Step 1 — Resolve image tags from cache
 
```yaml
- name: Set image versions
  run: |
    if [ "${{ needs.detect-changes.outputs.frontend }}" == "true" ]; then
      FRONTEND_VERSION="${{ github.sha }}"
    else
      FRONTEND_VERSION=$(cat frontend-sha.txt 2>/dev/null || echo "last version")
    fi
    # ...same pattern for inventory and notifications...
    echo "FRONTEND_VERSION=$FRONTEND_VERSION" >> $GITHUB_ENV
```
 
For each service: **if it was just built this run**, use the current commit SHA. **Otherwise**, restore the cached SHA file and use whatever's inside. The values are exported into `$GITHUB_ENV` so the rest of the job sees them as environment variables — and importantly, so does the compose file (`tests/docker-compose.yaml` references `${FRONTEND_VERSION}`, `${BACKEND_VERSION}`, `${NOTIFICATIONS_VERSION}` directly).
 
> Two minor inconsistencies live in this step: the inventory branch reads `backend-sha.txt` instead of `inventory-sha.txt` (so the read silently falls back to the literal string `"last version"`), and the notifications variable is named `notifications_VERSION` but the compose file expects `NOTIFICATIONS_VERSION`. Both have been working in practice because in current usage the changed service is always the one being tested, but they're worth cleaning up.
 
#### Step 2 — Pull and start
 
```yaml
- name: Pull images
  run: |
    docker pull ${{ secrets.DOCKER_USERNAME }}/devops2-frontend:${FRONTEND_VERSION}
    docker pull ${{ secrets.DOCKER_USERNAME }}/devops2-inventory:${BACKEND_VERSION}
    docker pull ${{ secrets.DOCKER_USERNAME }}/devops2-notifications:${NOTIFICATIONS_VERSION}
 
- name: Start services with docker compose
  run: docker compose -f tests/docker-compose.yaml up -d
```
 
Pulls all three images and brings them up via the test compose file (which is image-based, not build-based, unlike the root compose).
 
#### Step 3 — Wait for health
 
```yaml
- name: Wait for services to be ready
  run: |
    for i in {1..20}; do
      inventory=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/health || true)
      NOITICATION=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3002/health || true)
      FRONTEND=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/ || true)
      if [ "$FRONTEND" = "200" ] && [ "$inventory" = "200" ] && [ "$NOITICATION" = "200" ]; then
        echo "All services responding"
        break
      fi
      sleep 2
    done
```
 
Polls each `/health` endpoint up to 20 times with 2-second sleeps (≈40 seconds total). The `|| true` on each curl prevents a transient connection-refused (during startup) from aborting the script under `set -e`. The loop exits as soon as all three return 200 — typically within 5–10 seconds on warm runners.
 
#### Step 4 — Run the tests
 
```yaml
- name: Run integration tests
  run: bash ./tests/integration-tests.sh
```
 
Executes the bash test suite (see [Integration Tests](#integration-tests)). Non-zero exit fails the job.
 
#### Step 5 — Logs on failure
 
```yaml
- name: Dump logs on failure
  if: failure()
  run: |
    echo "═══ FRONTEND LOGS ═══"
    docker logs ci-frontend || true
    echo "═══ INVENTORY LOGS ═══"
    docker logs ci-inventory || true
    echo "═══ notifications LOGS ═══"
    docker logs ci-notifications || true
```
 
Only runs if the job failed. Dumps stdout/stderr from each container into the Actions log — usually enough to diagnose CI failures without needing to reproduce locally.
 
#### Step 6 — Cleanup
 
```yaml
- name: Cleanup
  if: always()
  run: docker compose -f tests/docker-compose.yaml down -v
```
 
`if: always()` guarantees this runs even if the test step failed. `-v` removes named volumes so the next job on the same runner starts clean.
 
### End-to-end flow
 
```
push to main (frontend changed)               manual dispatch (latest tag for inventory)
        │                                                    │
        ▼                                                    ▼
┌────────────────┐                                  ┌─────────────────┐
│ detect-changes │ → frontend=true                  │ detect-changes  │ → SKIPPED
│                │   inventory=false                │ (push-only gate)│
│                │   notifications=false            └─────────────────┘
└────────┬───────┘                                            │
         │                                                    │
         ▼                                                    ▼
┌──────────────────────────────────┐                ┌──────────────────────────────────┐
│ vulnerability-scanning (matrix)  │                │ vulnerability-scanning (matrix)  │
│   frontend       → SCANS         │                │   all 3 jobs run                 │
│   inventory      → step skipped  │                │   all 3 scan steps skipped       │
│   notifications  → step skipped  │                │   (no detect-changes outputs)    │
└────────┬─────────────────────────┘                └──────────┬───────────────────────┘
         │                                                     │
         ▼                                                     ▼
┌─────────────────┬──────────────┬──────────────┐   ┌─────────────────┬──────────────┬──────────────┐
│ build-frontend  │ build-invntr │ build-notifs │   │ build-frontend  │ build-invntr │ build-notifs │
│   RUNS          │   skipped    │   skipped    │   │   skipped       │   RUNS       │   skipped    │
│   tag = SHA     │              │              │   │                 │   tag=latest │              │
│   saves SHA in  │              │              │   │                 │   saves tag  │              │
│   cache         │              │              │   │                 │   in cache   │              │
└────────┬────────┴──────────────┴──────────────┘   └─────────────────┴──────┬───────┴──────────────┘
         │                                                                   │
         ▼                                                                   ▼
┌──────────────────────────────────────┐            ┌──────────────────────────────────────┐
│ integration-test                     │            │ integration-test                     │
│   FRONTEND_VERSION = current SHA     │            │   FRONTEND_VERSION = cached prev SHA │
│   BACKEND_VERSION  = cached prev SHA │            │   BACKEND_VERSION  = 'latest'        │
│   NOTIF_VERSION    = cached prev SHA │            │   NOTIF_VERSION    = cached prev SHA │
│   pull → up → wait → test → down     │            │   pull → up → wait → test → down     │
└──────────────────────────────────────┘            └──────────────────────────────────────┘
```
 
### Required GitHub Secrets and Variables
 
| Type | Name | Used by | Purpose |
|---|---|---|---|
| Secret | `DOCKER_USERNAME` | builds, integration test | Docker Hub username; also the image name prefix |
| Secret | `DOCKER_PASS` | builds, integration test | Docker Hub password or access token |
| Secret | `SONAR_TOKEN` | vulnerability-scanning | SonarCloud auth token |
| Secret | `DATABASE_URL` | integration test (`dev-env`) | Postgres URL the inventory container connects to |
| Secret | `SMTP_USER` | integration test (`dev-env`) | SMTP username for the test run |
| Secret | `SMTP_PASSWORD` | integration test (`dev-env`) | SMTP password (Gmail App Password recommended) |
| Variable | `SMTP_HOST` | integration test (`dev-env`) | e.g. `smtp.gmail.com` |
| Variable | `SMTP_PORT` | integration test (`dev-env`) | e.g. `587` |
| Variable | `SMTP_FROM` | integration test (`dev-env`) | "From" address |
| Variable | `ALERT_RECIPIENT` | integration test (`dev-env`) | Default alert recipient seeded into the DB |
 
The non-`dev-env` secrets (`DOCKER_*`, `SONAR_TOKEN`) live at the repo level. The integration-test environment-scoped secrets and variables live under **Settings → Environments → dev-env**, which lets you require manual approval before the test runs if you want a gate before pushing to a paid SMTP service.
 
### Published Images
 
After a successful run, three images are available on Docker Hub:
- `<DOCKER_USERNAME>/devops2-frontend:<tag>`
- `<DOCKER_USERNAME>/devops2-inventory:<tag>`
- `<DOCKER_USERNAME>/devops2-notifications:<tag>`
Where `<tag>` is either the commit SHA or `latest`, per the rules above. The Helm chart (`helm_chart/values.yaml`) is what consumes these tags for deployment.
 
---
 
## Integration Tests
 
`tests/` contains the integration test harness used by CI — and which you can also run locally against pre-built images.
 
### `tests/docker-compose.yaml`
Identical structure to the root compose file but **pulls images from Docker Hub by tag** instead of building from source. Tags are read from `${FRONTEND_VERSION}`, `${BACKEND_VERSION}`, and `${NOTIFICATIONS_VERSION}`, which CI populates from the build outputs / cache.
 
### `tests/integration-tests.sh`
A bash test runner that hits each service and counts pass/fail. Current cases:
 
- Inventory `/health` returns 200 and contains `"inventory"`.
- Notifications `/health` returns 200 and contains `"notification"`.
- Frontend serves HTML (response contains `<html`).
- Inventory `GET /products` returns a JSON array.
- Notifications `POST /notify` without a `to` field returns HTTP 400.
The script exits non-zero on any failure, which fails the GitHub Actions job. CI also dumps container logs from all three services on failure to make debugging from the Actions log straightforward.
 
### Running locally
 
```bash
export DOCKER_USERNAME=<your-dockerhub-user>
export FRONTEND_VERSION=<sha-or-latest>
export BACKEND_VERSION=<sha-or-latest>
export NOTIFICATIONS_VERSION=<sha-or-latest>
export DATABASE_URL=postgresql://...
export SMTP_HOST=smtp.gmail.com SMTP_PORT=587
export SMTP_USER=... SMTP_PASSWORD=... SMTP_FROM=... ALERT_RECIPIENT=...
 
docker compose -f tests/docker-compose.yaml up -d
bash tests/integration-tests.sh
docker compose -f tests/docker-compose.yaml down -v
```
 
---
 
## Local Development
 
### Run a single service without rebuilding the image
 
```bash
# Notifications service
cd notifications-service
pip install -r requirements.txt
SMTP_USER=... SMTP_PASSWORD=... python app.py
 
# Inventory service
cd inventory-service
npm install
DATABASE_URL=... node index.js
 
# Frontend
cd frontend
npm install
API=http://localhost:3000 node server.js
```
 
Each service reads its config from environment variables, so just `export` them in your shell or use a tool like `direnv`.
 
### Tail logs
 
```bash
docker compose logs -f                    # all services, live
docker compose logs -f notification       # one service
docker compose logs --tail=50 inventory   # last 50 lines
docker compose logs inventory | grep -i error
```
 
### Rebuild after a code change
 
```bash
docker compose up --build -d frontend          # rebuild + restart one service
docker compose build --no-cache inventory      # force a clean rebuild
docker compose up -d inventory
```
 
---
 
## Troubleshooting
 
**Frontend shows "INVENTORY SERVICE OFFLINE"**
The browser can't reach the inventory service.
- Is it running? `docker compose ps`
- Does `curl http://localhost:3000/health` work from your terminal?
- Open DevTools → Console and look for CORS errors.
- Verify `CORS_ORIGIN=*` (or the appropriate origin) in `.env`.
**Port already in use**
```
Error: bind: address already in use
```
Find what's holding it and stop it, or change the port in `.env`:
```bash
lsof -i :8000
```
 
**Notifications service crash-loops**
Almost always missing SMTP credentials. Check the logs:
```bash
docker compose logs notification
```
If you see `SMTP_USER and SMTP_PASSWORD env vars are required`, fill them in and restart.
 
**Email not arriving**
1. Check notifications logs for auth errors — the service is verbose about each failure mode.
2. Confirm you're using a **Gmail App Password** (16 chars), not your regular password.
3. Test the endpoint directly:
   ```bash
   curl -X POST http://localhost:3002/notify \
     -H 'Content-Type: application/json' \
     -d '{"to":"you@example.com","subject":"Test","message":"Hello"}'
   ```
4. Check the spam folder.
**Helm install completes but pods are `CrashLoopBackOff`**
- `kubectl logs <pod> -n stockwatch` — usually a missing/wrong env var (DATABASE_URL, SMTP_*).
- `kubectl describe pod <pod>` — check the events at the bottom for image-pull errors.
- Confirm the Secret was rendered:
  ```bash
  kubectl get secret -n stockwatch <secret-name> -o yaml
  echo '<base64>' | base64 -d   # decode and check it's actually right
  ```
 
**CI integration test fails but builds succeeded**
Check the "Dump logs on failure" step in the Actions log — it prints stdout/stderr from all three CI containers.
 
---
 
## License

MIT — do whatever you want with this code.

---

## Acknowledgments
This project is under continous devopment
Built as a DevOps learning exercise by [mahmooud](https://github.com/mkmahmoud)
 


