# RKE2 Cluster Bootstrapping - Quick Reference

## Architecture Overview

### Standard Setup
```
┌─────────────────────────────────────────────────────────────┐
│                        VirtualBox Host                       │
│                                                               │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐        │
│  │jumpbox  │  │ server  │  │ node-0  │  │ node-1  │        │
│  │512MB    │  │  4GB    │  │  4GB    │  │  4GB    │        │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘        │
│       │            │            │            │               │
│       └────────────┴────────────┴────────────┘               │
│                  NAT Network                                  │
└─────────────────────────────────────────────────────────────┘
```

### HA Setup (3 Servers)
```
┌──────────────────────────────────────────────────────────────────┐
│                         VirtualBox Host                          │
│                                                                    │
│  ┌─────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐         │
│  │jumpbox  │  │ server-0 │  │ server-1 │  │ server-2 │         │
│  │512MB    │  │   4GB    │  │   4GB    │  │   4GB    │         │
│  └────┬────┘  └─────┬────┘  └─────┬────┘  └─────┬────┘         │
│       │             │              │             │               │
│       │       ┌─────┴──────────────┴─────┐       │               │
│       │       │  Embedded etcd Cluster   │       │               │
│       │       └──────────────────────────┘       │               │
│       │                                           │               │
│       │       ┌──────────┐       ┌──────────┐   │               │
│       │       │  node-0  │       │  node-1  │   │               │
│       │       │   4GB    │       │   4GB    │   │               │
│       │       └────┬─────┘       └────┬─────┘   │               │
│       │            │                   │         │               │
│       └────────────┴───────────────────┴─────────┘               │
│                      NAT Network                                  │
└──────────────────────────────────────────────────────────────────┘
```

## Quick Commands

### Setup Commands
```bash
# Standard setup (1 server, 2 workers)
./setup-cluster.sh

# HA setup (3 servers, 2 workers)
./setup-cluster.sh --ha-mode -m vm/machines-ha.txt

# Partial setup (skip jumpbox)
./setup-cluster.sh --skip-jumpbox

# Without ArgoCD (direct HelmCharts)
./setup-cluster.sh --no-argocd
```

### Cluster Access
```bash
# SSH to server
ssh root@server  # or server-0 for HA

# Setup kubectl
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin

# Check cluster
kubectl get nodes
kubectl get pods -A
```

### ArgoCD Commands
```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d

# List applications
kubectl get applications -n argocd

# Sync application
argocd app sync rancher

# View application status
argocd app get rancher
```

### Service Access URLs
```
Rancher:  https://virtualbox.local
ArgoCD:   https://argocd.virtualbox.local
Grafana:  https://grafana.virtualbox.local
Hubble:   kubectl port-forward -n kube-system svc/hubble-ui 12000:80
```

### Default Credentials
```
Rancher:  admin / admin
Grafana:  admin / admin
ArgoCD:   admin / <from secret>
```

## File Structure

### Configuration Files
```
server/config/
├── server.yaml           # Standard single server config
├── server-ha.yaml        # HA first server config
└── server-ha-join.yaml   # HA additional servers config

agent/config/
├── agent_0.yaml          # Agent node 0 (with ingress)
├── agent_1.yaml          # Agent node 1
└── server_token.yaml     # Token template

vm/
├── machines.txt          # Standard setup IPs
├── machines-ha.txt       # HA setup IPs
└── setup.sh             # Legacy jumpbox setup
```

### Manifests
```
server/manifests/
├── rke2-*.yaml                    # RKE2 component configs
├── cert-manager.yaml              # Direct cert-manager (no ArgoCD)
├── rancher.yaml                   # Direct rancher (no ArgoCD)
├── argocd.yaml                    # ArgoCD deployment
├── argocd-app-of-apps.yaml        # App-of-Apps pattern
└── argocd-apps/                   # ArgoCD Applications
    ├── cert-manager-app.yaml
    ├── rancher-app.yaml
    ├── loki-app.yaml
    ├── grafana-app.yaml
    ├── tempo-app.yaml
    └── mimir-app.yaml
```

## Deployment Flow

### Automated (Recommended)
```
1. Edit vm/machines.txt with actual IPs
2. scp files to jumpbox
3. Run ./setup-cluster.sh
4. Wait for completion (~10-15 minutes)
5. Access services via URLs
```

### Manual Setup Flow
```
1. Setup VMs
   └─> Configure network, SSH

2. Setup Jumpbox
   └─> Install tools, SSH keys, hosts file

3. Setup Server(s)
   └─> Install RKE2
   └─> Copy configs and manifests
   └─> Start rke2-server service
   └─> Wait for cluster ready

4. Setup Agents
   └─> Get server token
   └─> Install RKE2 agent
   └─> Join cluster
   └─> Start rke2-agent service

5. Deploy Applications (via ArgoCD)
   └─> ArgoCD deployed by RKE2
   └─> App-of-Apps creates all applications
   └─> Applications sync automatically
```

## Component Stack

### Infrastructure Layer
- **RKE2**: Kubernetes distribution
- **Cilium**: CNI with WireGuard encryption
- **etcd**: Embedded (HA) or external
- **ServiceLB**: Load balancer for bare metal

### Platform Layer
- **cert-manager**: TLS certificate management
- **Rancher**: Cluster management UI
- **Ingress-nginx**: Ingress controller

### GitOps Layer
- **ArgoCD**: GitOps continuous delivery

### Observability Layer (LGTM Stack)
- **Loki**: Log aggregation
- **Grafana**: Visualization and dashboards
- **Tempo**: Distributed tracing
- **Mimir**: Prometheus metrics storage

## Troubleshooting Quick Checks

### Service Status
```bash
# Server
systemctl status rke2-server
journalctl -u rke2-server -f

# Agent
systemctl status rke2-agent
journalctl -u rke2-agent -f
```

### Pod Status
```bash
# All pods
kubectl get pods -A

# Specific namespaces
kubectl get pods -n kube-system
kubectl get pods -n argocd
kubectl get pods -n lgtm-stack
kubectl get pods -n cattle-system
```

### Network Connectivity
```bash
# Cilium status
kubectl -n kube-system exec -it ds/rke2-cilium -- cilium status

# Hubble flows
kubectl -n kube-system exec -it ds/rke2-cilium -- hubble observe

# DNS
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup kubernetes.default
```

### ArgoCD Sync Issues
```bash
# Force refresh
kubectl -n argocd patch application <app-name> \
  --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"true"}}}'

# Check sync status
kubectl get applications -n argocd
kubectl describe application <app-name> -n argocd
```

## Key Features

### High Availability
- ✓ Multiple server nodes (embedded etcd)
- ✓ Quorum-based consensus
- ✓ Automatic failover
- ✓ Workload isolation (server taints)

### Security
- ✓ CIS hardening profile
- ✓ Pod Security Admission
- ✓ WireGuard encryption
- ✓ RBAC enabled

### Observability
- ✓ Metrics (Mimir/Prometheus)
- ✓ Logs (Loki)
- ✓ Traces (Tempo)
- ✓ Dashboards (Grafana)
- ✓ Network (Hubble)

### Automation
- ✓ One-command deployment
- ✓ GitOps with ArgoCD
- ✓ Automated sync
- ✓ Self-healing

## Next Steps

1. **Customize** configurations for your environment
2. **Secure** with proper TLS certificates
3. **Scale** by adding more worker nodes
4. **Monitor** with custom Grafana dashboards
5. **Deploy** your applications via ArgoCD

For detailed information, see the full [README.md](README.md).
