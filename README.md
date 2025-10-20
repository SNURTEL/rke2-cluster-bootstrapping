# RKE2 Cluster Bootstrapping

This repo provides a guide to bootstrapping an RKE2 ([Rancher Kubernetes Engine](https://docs.rke2.io/)) cluster with a few sensible defaults:

- Cilium CNI with WireGuard tunnelling, kube-proxy replacement
- **High Availability (HA) mode with multiple server nodes**
- **ArgoCD GitOps for continuous deployment**
- Rancher cluster management via ArgoCD
- **LGTM observability stack (Loki, Grafana, Tempo, Mimir) via ArgoCD**
- Hubble network observability
- CSI compliance by default
- ServiceLB load balancer controller
- **Automated setup script for quick deployment**

You can try it out using VirtualBox. Please note that some practices presented here would be at least questionable in a production environment (limited host hardening, self-signed control plane certs), but were simplified since they will strongly differ depending on environment configuration.

## Quick Start (Automated Setup)

The fastest way to get started is using the automated setup script:

```shell
# Copy the script and machines file to the jumpbox
JUMPBOX_IP=<JUMPBOX_HOSTONLY_IP>
scp setup-cluster.sh vm/machines.txt root@$JUMPBOX_IP:/root/

# SSH to jumpbox and run the script
ssh root@$JUMPBOX_IP

# Standard setup (single server)
bash setup-cluster.sh

# HA setup (3 server nodes)
bash setup-cluster.sh --ha-mode

# For more options
bash setup-cluster.sh --help
```

The script will automatically:
1. Configure the jumpbox
2. Setup server node(s) with RKE2
3. Deploy ArgoCD via RKE2's built-in Helm controller
4. Setup ArgoCD Applications for Rancher and LGTM stack
5. Setup agent nodes
6. Verify the cluster

Continue reading for manual setup instructions or to understand the architecture.

## VM setup

Assuming you have VirtualBox installed:

- Download the latest `raw` Debian image in `nocloud` flavor: https://cloud.debian.org/images/cloud/

- Convert the image to VDI:

```shell
VBoxManage convertfromraw debian-12-nocloud-amd64-<REVISION>.raw  debian-12-nocloud-amd64-<REVISION>.vdi --format VDI
```

Create four VMs with the following resources (specs taken from the awesome [Kubernetes The Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way) project):

**Standard Setup (Single Server):**

| Name    | Description            | CPU | RAM   | Storage |
|---------|------------------------|-----|-------|---------|
| jumpbox | Administration host    | 1   | 512MB | 10GB    |
| server  | Kubernetes server      | 1   | 4GB   | 20GB    |
| node-0  | Kubernetes worker node | 1   | 4GB   | 20GB    |
| node-1  | Kubernetes worker node | 1   | 4GB   | 20GB    |

**HA Setup (Multiple Servers):**

| Name     | Description            | CPU | RAM   | Storage |
|----------|------------------------|-----|-------|---------|
| jumpbox  | Administration host    | 1   | 512MB | 10GB    |
| server-0 | Kubernetes server      | 1   | 4GB   | 20GB    |
| server-1 | Kubernetes server      | 1   | 4GB   | 20GB    |
| server-2 | Kubernetes server      | 1   | 4GB   | 20GB    |
| node-0   | Kubernetes worker node | 1   | 4GB   | 20GB    |
| node-1   | Kubernetes worker node | 1   | 4GB   | 20GB    |

- Do not specify an ISO image and use the VDI file as volume. Create a NAT network and two Host-only networks and attach network interfaces to VMs as follows:

**Standard Setup:**

| Name    | Interfaces                                |
|---------|-------------------------------------------|
| jumpbox | NAT network, Host-only 1 (for SSH access) |
| server  | NAT network                               |
| node-0  | NAT network, Host-only 2 (for ingress)    |
| node-1  | NAT network                               |

**HA Setup:**

| Name     | Interfaces                                |
|----------|-------------------------------------------|
| jumpbox  | NAT network, Host-only 1 (for SSH access) |
| server-0 | NAT network                               |
| server-1 | NAT network                               |
| server-2 | NAT network                               |
| node-0   | NAT network, Host-only 2 (for ingress)    |
| node-1   | NAT network                               |

- Boot all machines, login as `root` with no password using the VirtualBox terminal. Configure SSH access on all machines:

```shell
apt-get update && apt-get install -y openssh-server && sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && systemctl daemon-reload && systemctl restart sshd && echo "root:toor" | chpasswd
```

- Edit the `vm/machines.txt` file (for standard setup) or `vm/machines-ha.txt` (for HA setup) and replace the IP addresses with IPv4 addresses of server(s) and nodes bound to NAT-network interfaces. Then, copy the file to the jumpbox and run the setup script:

```shell
JUMPBOX_IP=<JUMPBOX_HOSTONLY_IP>

# For standard setup
scp vm/machines.txt setup-cluster.sh root@$JUMPBOX_IP:/root/
ssh root@$JUMPBOX_IP bash setup-cluster.sh

# For HA setup
scp vm/machines-ha.txt setup-cluster.sh root@$JUMPBOX_IP:/root/
ssh root@$JUMPBOX_IP bash setup-cluster.sh --ha-mode -m machines-ha.txt
```

Note: if you're using dynamic allocation for the VM's disk, you may want to increase the partition size to full on server and node VMs:

```shell
df -h  # proceed if /dev/sda1 is smaller than 20 GiB

apt-get -y install parted
echo 1 > /sys/block/sda/device/rescan

parted

# from parted console
(parted) print free # should show a lot of unused space

(parted) resizepart 1 100%
```

Then, reboot the VMs.

## Server node setup

SSH to **server**, then:

- Create the config file (see the example config in `server/config/server.yaml`):

```shell
mkdir -p /etc/rancher/rke2/config.yaml.d
vim /etc/rancher/rke2/config.yaml.d/00-server.yaml
```

- Run the server installation script:

```shell
curl -sfL https://get.rke2.io | sh -
```

Set the required kernel params (needed for CIS compliance):

```shell
cp -f /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
systemctl restart systemd-sysctl
```

Create the `etcd` user to run the Etcd DB (also needed for CIS compliance):

```shell
useradd -r -c "etcd user" -s /sbin/nologin -M etcd -U
```

Put all necessary manifests in place:

```shell
mkdir -p /var/lib/rancher/rke2/server/manifests/
vim /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
vim /var/lib/rancher/rke2/server/manifests/rke2-coredns-config.yaml
vim /var/lib/rancher/rke2/server/manifests/rke2-ingress-nginx-config.yaml
# continue for every file in `server/manifests`
```

Copy the `server/rke2-pss-override.yaml` file to `/etc/rancher/rke2/rke2-pss-override.yaml` (needed to configure namespace exemptions, you will have a bad time installing anything without them).

Enable and start the service, check logs to see if everything looks good:

```shell
systemctl enable rke2-server.service
systemctl start rke2-server.service

# run in separate session
journalctl -u rke2-server -f
```

Check service health:

```shell
systemctl status rke2-server
```

## Agent node setup

Move back to jumpbox. Pull the generated token for joining the cluster:

```shell
scp root@server:/var/lib/rancher/rke2/server/node-token rke2-token
```

Prepare the config file with server connection details:

```shell
cat << 'EOF' > 01-server-token.yaml
---
server: https://server:9345
token: <TOKEN>
EOF
sed -i "s/<TOKEN>/$(cat rke2-token)/" 01-server-token.yaml
```

For each node:

- Copy config files (again, check recommended configuration in `agent/config`):

```shell
NODE_NUM=0
ssh root@node-$NODE_NUM mkdir -p /etc/rancher/rke2/config.yaml.d
scp 01-server-token.yaml root@node-$NODE_NUM:/etc/rancher/rke2/config.yaml.d/01-server-token.yaml
ssh -t root@node-$NODE_NUM vim /etc/rancher/rke2/config.yaml.d/00-agent-$NODE_NUM.yaml
```

**NOTE** since `node-0` is configured as ingress, you will need to modify `agent/config/agent_0.yaml` and replace `node-external-ip` with IP bound to VM's Host-only interface. Also, add the same IP to your `/etc/hosts` as `virtualbox.local` - then you should be able to access Rancher at `https://virtualbox.local`.

- Connect to the node:

```shell
ssh root@node-$NODE_NUM
```

- Run the installation script:

```shell
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh -
```

- Set the required kernel params (needed for CIS compliance):

```shell
cp -f /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
systemctl restart systemd-sysctl
```

- Enable and start the service, check logs to see if everything looks good:

```shell
systemctl enable rke2-agent.service
systemctl start rke2-agent.service

# run in separate session
journalctl -u rke2-agent -f
```

- Check service health:

```shell
systemctl status rke2-agent
```

## Test

SSH to the server host and utilize the generated kubeconfig:

```shell
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin
```

Then:

```shell
kubectl version
kubectl cluster-info
kubectl get nodes
kubectl get pods --all-namespaces
```

## ArgoCD GitOps Setup

This setup includes ArgoCD for GitOps-based deployments. ArgoCD is deployed via RKE2's built-in Helm controller.

### Access ArgoCD

Get the initial admin password:

```shell
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

Access ArgoCD UI at `https://argocd.virtualbox.local` with username `admin` and the password from above.

### ArgoCD Applications

The following applications are automatically deployed via the App-of-Apps pattern:

1. **cert-manager** - Certificate management for TLS
2. **Rancher** - Kubernetes management platform (HA mode with 3 replicas)
3. **Loki** - Log aggregation system
4. **Grafana** - Metrics visualization and dashboards
5. **Tempo** - Distributed tracing backend
6. **Mimir** - Prometheus-compatible metrics storage

All applications are configured with:
- Automated sync (prune and self-heal enabled)
- Namespace creation
- LoadBalancer services for external access

### Managing Applications

```shell
# View all applications
kubectl get applications -n argocd

# Sync an application manually
kubectl -n argocd patch application rancher --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"true"}}}'

# View application status
argocd app get rancher
```

## LGTM Stack Access

The LGTM (Loki, Grafana, Tempo, Mimir) observability stack is deployed in the `lgtm-stack` namespace.

### Grafana

Access Grafana at `https://grafana.virtualbox.local` with default credentials:
- Username: `admin`
- Password: `admin` (you'll be prompted to change on first login)

Grafana comes pre-configured with datasources for:
- **Mimir** (Prometheus) - metrics
- **Loki** - logs
- **Tempo** - traces

### Loki

Logs can be queried via Grafana's Explore view or directly:

```shell
kubectl port-forward -n lgtm-stack svc/loki-gateway 3100:80
# Query logs: http://localhost:3100/loki/api/v1/query?query={namespace="default"}
```

### Tempo

Traces can be viewed in Grafana's Explore view. Tempo is accessible at:

```shell
kubectl port-forward -n lgtm-stack svc/tempo 3100:3100
```

### Mimir

Metrics are stored in Mimir and can be queried via Grafana's dashboard or Prometheus-compatible APIs:

```shell
kubectl port-forward -n lgtm-stack svc/mimir-gateway 8080:80
# Query metrics: http://localhost:8080/prometheus/api/v1/query?query=up
```

## High Availability (HA) Mode

This setup supports HA mode with multiple server nodes for production-grade deployments.

### HA Architecture

- **3+ Server Nodes**: Recommended minimum for HA (odd number for etcd quorum)
- **Embedded etcd**: Uses RKE2's embedded etcd for simplicity
- **Load Balancing**: First server acts as the initial join point
- **Workload Isolation**: Server nodes are tainted to prevent workload scheduling

### HA Configuration

The HA setup uses different configuration files:

- `server/config/server-ha.yaml` - First server node configuration
- `server/config/server-ha-join.yaml` - Additional server nodes configuration

Key differences from standard setup:
- Added TLS SANs for all server nodes
- Server taints enabled (`CriticalAddonsOnly=true:NoExecute`)
- Rancher replicas increased to 3

### Setting up HA Manually

If not using the automated script:

1. Setup the first server node with `server-ha.yaml` config
2. Wait for it to be fully ready
3. Retrieve the node token: `cat /var/lib/rancher/rke2/server/node-token`
4. Setup additional servers with `server-ha-join.yaml`, replacing `<TOKEN>`
5. Verify all servers are ready: `kubectl get nodes`

### External etcd (Optional)

For production environments, consider using external etcd for better resilience:

```yaml
# In server config
datastore-endpoint: "https://etcd-0:2379,https://etcd-1:2379,https://etcd-2:2379"
datastore-cafile: /path/to/ca.crt
datastore-certfile: /path/to/cert.crt
datastore-keyfile: /path/to/key.pem
```

## Automation Script Reference

The `setup-cluster.sh` script automates the entire setup process.

### Usage

```shell
./setup-cluster.sh [OPTIONS]

Options:
    -h, --help              Show help message
    -m, --machines FILE     Path to machines.txt file (default: ./machines.txt)
    -a, --ha-mode           Enable HA mode with multiple server nodes
    --no-argocd             Skip ArgoCD deployment (use direct HelmCharts)
    --skip-jumpbox          Skip jumpbox setup (already configured)
    --skip-server           Skip server setup (already configured)
    --skip-agents           Skip agent setup (already configured)
```

### Examples

```shell
# Standard single server setup
./setup-cluster.sh

# HA setup with custom machines file
./setup-cluster.sh --ha-mode -m vm/machines-ha.txt

# Skip already configured components
./setup-cluster.sh --skip-jumpbox --skip-server

# Setup without ArgoCD (use direct HelmCharts)
./setup-cluster.sh --no-argocd
```

### What the Script Does

1. **Prerequisites Check**: Validates required tools (ssh, scp, kubectl)
2. **Jumpbox Setup**: Installs packages, generates SSH keys, configures hosts
3. **Server Setup**: Installs RKE2, configures CIS compliance, deploys manifests
4. **Agent Setup**: Joins worker nodes to the cluster
5. **Verification**: Checks cluster health and node status
6. **Access Info**: Provides URLs and credentials for services

## Troubleshooting

### Check Service Status

```shell
# On server nodes
systemctl status rke2-server
journalctl -u rke2-server -f

# On agent nodes
systemctl status rke2-agent
journalctl -u rke2-agent -f
```

### ArgoCD Issues

```shell
# Check ArgoCD pods
kubectl get pods -n argocd

# View application sync status
kubectl get applications -n argocd

# Force application sync
kubectl -n argocd patch application <app-name> --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"true"}}}'
```

### LGTM Stack Issues

```shell
# Check LGTM stack pods
kubectl get pods -n lgtm-stack

# View Grafana logs
kubectl logs -n lgtm-stack deployment/grafana

# View Loki logs
kubectl logs -n lgtm-stack deployment/loki
```

### Network Connectivity

```shell
# Test pod-to-pod connectivity
kubectl run -it --rm debug --image=busybox --restart=Never -- sh

# Check Cilium status
kubectl -n kube-system exec -it ds/rke2-cilium -- cilium status

# View Hubble flows
kubectl -n kube-system exec -it ds/rke2-cilium -- hubble observe
```

## Production Considerations

This setup is optimized for learning and testing. For production deployments:

1. **Security Hardening**
   - Use proper TLS certificates (not self-signed)
   - Enable authentication and RBAC
   - Harden host systems (CIS benchmarks)
   - Use secrets management (Vault, Sealed Secrets)

2. **High Availability**
   - Deploy 3+ server nodes across availability zones
   - Use external etcd with backup/restore
   - Configure proper load balancing
   - Implement disaster recovery procedures

3. **Monitoring & Observability**
   - Configure persistent storage for LGTM stack
   - Set up alerting rules
   - Configure log retention policies
   - Implement proper backup strategies

4. **Resource Management**
   - Size nodes appropriately for workloads
   - Configure resource quotas and limits
   - Use pod disruption budgets
   - Implement horizontal pod autoscaling

5. **GitOps Best Practices**
   - Use private Git repositories
   - Implement proper Git workflows (PR reviews)
   - Use ArgoCD Projects for multi-tenancy
   - Configure webhook-based sync for faster deployments

