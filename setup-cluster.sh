#!/bin/bash

# RKE2 Cluster Bootstrapping Automation Script
# This script automates the setup process documented in README.md
# Run this script from the jumpbox VM

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACHINES_FILE="${MACHINES_FILE:-${SCRIPT_DIR}/machines.txt}"
HA_MODE="${HA_MODE:-false}"
SETUP_ARGOCD="${SETUP_ARGOCD:-true}"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    -h, --help              Show this help message
    -m, --machines FILE     Path to machines.txt file (default: ./machines.txt)
    -a, --ha-mode           Enable HA mode with multiple server nodes
    --no-argocd             Skip ArgoCD deployment
    --skip-jumpbox          Skip jumpbox setup (already configured)
    --skip-server           Skip server setup (already configured)
    --skip-agents           Skip agent setup (already configured)

Environment Variables:
    HA_MODE                 Set to 'true' to enable HA mode
    SETUP_ARGOCD            Set to 'false' to skip ArgoCD
    MACHINES_FILE           Path to machines.txt file

Examples:
    # Standard single server setup
    $0

    # HA mode with 3 server nodes
    $0 --ha-mode

    # Skip already configured components
    $0 --skip-jumpbox --skip-server
EOF
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local required_commands=("ssh" "scp" "ssh-keygen" "sshpass")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command '$cmd' not found. Please install it first."
            exit 1
        fi
    done
    
    if [ ! -f "$MACHINES_FILE" ]; then
        log_error "Machines file not found: $MACHINES_FILE"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

setup_jumpbox() {
    log_info "Setting up jumpbox..."
    
    # Update apt sources
    log_info "Updating apt sources..."
    echo "deb http://ftp.de.debian.org/debian/ bookworm main non-free-firmware non-free contrib" >> /etc/apt/sources.list
    echo "deb http://ftp.de.debian.org/debian/ bookworm-updates main non-free-firmware non-free contrib" >> /etc/apt/sources.list
    echo "deb http://ftp.de.debian.org/debian-security/ bookworm-security main non-free-firmware non-free contrib" >> /etc/apt/sources.list
    
    # Install required packages
    log_info "Installing required packages..."
    apt-get update && apt-get install -y wget curl vim openssl git sshpass kubectl
    
    # Generate SSH key if not exists
    if [ ! -f ~/.ssh/id_rsa ]; then
        log_info "Generating SSH key..."
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -P ""
    fi
    
    # Setup hosts file
    log_info "Setting up /etc/hosts..."
    while read IP FQDN HOST SUBNET; do
        ENTRY="${IP} ${FQDN} ${HOST}"
        if ! grep -q "$HOST" /etc/hosts; then
            echo "$ENTRY" >> /etc/hosts
        fi
    done < "$MACHINES_FILE"
    
    # Distribute SSH keys
    log_info "Distributing SSH keys..."
    while read IP FQDN HOST SUBNET; do
        sshpass -p toor ssh-copy-id -o StrictHostKeyChecking=no root@${IP} 2>/dev/null || true
        ssh -n root@${HOST} hostname
    done < "$MACHINES_FILE"
    
    log_success "Jumpbox setup complete"
}

configure_machine_hostnames() {
    log_info "Configuring machine hostnames..."
    
    while read IP FQDN HOST SUBNET; do
        log_info "Configuring $HOST..."
        
        CMD="sed -i 's/^127.0.1.1.*/127.0.1.1\t${FQDN} ${HOST}/' /etc/hosts"
        ssh -n root@${HOST} "$CMD"
        ssh -n root@${HOST} hostnamectl set-hostname ${HOST}
        ssh -n root@${HOST} systemctl restart systemd-hostnamed
        ssh -n root@${HOST} hostname --fqdn
    done < "$MACHINES_FILE"
    
    log_success "Machine hostnames configured"
}

setup_server_node() {
    local server_host=$1
    local is_first_server=${2:-true}
    
    log_info "Setting up server node: $server_host..."
    
    # Create config directory
    ssh root@${server_host} "mkdir -p /etc/rancher/rke2/config.yaml.d"
    
    # Copy appropriate server config
    if [ "$is_first_server" = "true" ]; then
        log_info "Copying first server config..."
        scp "${SCRIPT_DIR}/../server/config/server.yaml" \
            root@${server_host}:/etc/rancher/rke2/config.yaml.d/00-server.yaml
    else
        log_info "Copying HA join server config..."
        # First, get the token from the first server
        local first_server=$(grep "server" "$MACHINES_FILE" | head -1 | awk '{print $3}')
        local token=$(ssh root@${first_server} "cat /var/lib/rancher/rke2/server/node-token")
        
        scp "${SCRIPT_DIR}/../server/config/server-ha-join.yaml" \
            root@${server_host}:/etc/rancher/rke2/config.yaml.d/00-server.yaml
        
        # Replace token placeholder
        ssh root@${server_host} "sed -i 's/<TOKEN>/${token}/' /etc/rancher/rke2/config.yaml.d/00-server.yaml"
    fi
    
    # Install RKE2 server
    log_info "Installing RKE2 server..."
    ssh root@${server_host} "curl -sfL https://get.rke2.io | sh -"
    
    # Setup CIS compliance
    log_info "Configuring CIS compliance..."
    ssh root@${server_host} "cp -f /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf"
    ssh root@${server_host} "systemctl restart systemd-sysctl"
    ssh root@${server_host} "useradd -r -c 'etcd user' -s /sbin/nologin -M etcd -U 2>/dev/null || true"
    
    # Copy manifests (only on first server)
    if [ "$is_first_server" = "true" ]; then
        log_info "Copying manifests..."
        ssh root@${server_host} "mkdir -p /var/lib/rancher/rke2/server/manifests/"
        
        # Copy RKE2 config manifests
        scp "${SCRIPT_DIR}/../server/manifests/rke2-"*.yaml \
            root@${server_host}:/var/lib/rancher/rke2/server/manifests/
        
        # Copy cert-manager and rancher if not using ArgoCD
        if [ "$SETUP_ARGOCD" = "false" ]; then
            scp "${SCRIPT_DIR}/../server/manifests/cert-manager.yaml" \
                root@${server_host}:/var/lib/rancher/rke2/server/manifests/
            scp "${SCRIPT_DIR}/../server/manifests/rancher.yaml" \
                root@${server_host}:/var/lib/rancher/rke2/server/manifests/
        else
            # Copy ArgoCD manifest
            scp "${SCRIPT_DIR}/../server/manifests/argocd.yaml" \
                root@${server_host}:/var/lib/rancher/rke2/server/manifests/
            scp "${SCRIPT_DIR}/../server/manifests/argocd-app-of-apps.yaml" \
                root@${server_host}:/var/lib/rancher/rke2/server/manifests/
        fi
        
        # Copy PSS override
        scp "${SCRIPT_DIR}/../server/rke2-pss-override,yaml" \
            root@${server_host}:/etc/rancher/rke2/rke2-pss-override.yaml
    fi
    
    # Enable and start service
    log_info "Starting RKE2 server service..."
    ssh root@${server_host} "systemctl enable rke2-server.service"
    ssh root@${server_host} "systemctl start rke2-server.service"
    
    # Wait for service to be ready
    log_info "Waiting for RKE2 server to be ready..."
    local max_retries=30
    local retry_count=0
    while [ $retry_count -lt $max_retries ]; do
        if ssh root@${server_host} "systemctl is-active rke2-server.service" &> /dev/null; then
            log_success "RKE2 server is active"
            break
        fi
        retry_count=$((retry_count + 1))
        sleep 10
    done
    
    if [ $retry_count -eq $max_retries ]; then
        log_error "RKE2 server failed to start on $server_host"
        ssh root@${server_host} "journalctl -u rke2-server -n 50"
        return 1
    fi
    
    log_success "Server node $server_host setup complete"
}

setup_agent_node() {
    local node_host=$1
    local node_num=$2
    
    log_info "Setting up agent node: $node_host..."
    
    # Get server token
    local first_server=$(grep "server" "$MACHINES_FILE" | head -1 | awk '{print $3}')
    local token=$(ssh root@${first_server} "cat /var/lib/rancher/rke2/server/node-token")
    
    # Create config directory
    ssh root@${node_host} "mkdir -p /etc/rancher/rke2/config.yaml.d"
    
    # Create server token config
    cat > /tmp/01-server-token.yaml << EOF
---
server: https://${first_server}:9345
token: ${token}
EOF
    scp /tmp/01-server-token.yaml root@${node_host}:/etc/rancher/rke2/config.yaml.d/01-server-token.yaml
    rm -f /tmp/01-server-token.yaml
    
    # Copy agent config
    if [ -f "${SCRIPT_DIR}/../agent/config/agent_${node_num}.yaml" ]; then
        scp "${SCRIPT_DIR}/../agent/config/agent_${node_num}.yaml" \
            root@${node_host}:/etc/rancher/rke2/config.yaml.d/00-agent.yaml
    else
        # Create default agent config
        cat > /tmp/00-agent.yaml << EOF
---
profile: cis
node-label+:
  - "svccontroller.rke2.cattle.io/enablelb=true"
EOF
        scp /tmp/00-agent.yaml root@${node_host}:/etc/rancher/rke2/config.yaml.d/00-agent.yaml
        rm -f /tmp/00-agent.yaml
    fi
    
    # Install RKE2 agent
    log_info "Installing RKE2 agent..."
    ssh root@${node_host} "curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE='agent' sh -"
    
    # Setup CIS compliance
    log_info "Configuring CIS compliance..."
    ssh root@${node_host} "cp -f /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf"
    ssh root@${node_host} "systemctl restart systemd-sysctl"
    
    # Enable and start service
    log_info "Starting RKE2 agent service..."
    ssh root@${node_host} "systemctl enable rke2-agent.service"
    ssh root@${node_host} "systemctl start rke2-agent.service"
    
    # Wait for service to be ready
    log_info "Waiting for RKE2 agent to be ready..."
    local max_retries=20
    local retry_count=0
    while [ $retry_count -lt $max_retries ]; do
        if ssh root@${node_host} "systemctl is-active rke2-agent.service" &> /dev/null; then
            log_success "RKE2 agent is active"
            break
        fi
        retry_count=$((retry_count + 1))
        sleep 10
    done
    
    if [ $retry_count -eq $max_retries ]; then
        log_error "RKE2 agent failed to start on $node_host"
        ssh root@${node_host} "journalctl -u rke2-agent -n 50"
        return 1
    fi
    
    log_success "Agent node $node_host setup complete"
}

verify_cluster() {
    log_info "Verifying cluster..."
    
    local first_server=$(grep "server" "$MACHINES_FILE" | head -1 | awk '{print $3}')
    
    log_info "Checking nodes..."
    ssh root@${first_server} "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml && export PATH=\$PATH:/var/lib/rancher/rke2/bin && kubectl get nodes"
    
    log_info "Checking pods..."
    ssh root@${first_server} "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml && export PATH=\$PATH:/var/lib/rancher/rke2/bin && kubectl get pods --all-namespaces"
    
    log_success "Cluster verification complete"
}

print_access_info() {
    log_success "====================================="
    log_success "RKE2 Cluster Setup Complete!"
    log_success "====================================="
    
    local first_server=$(grep "server" "$MACHINES_FILE" | head -1 | awk '{print $3}')
    
    echo ""
    log_info "To access the cluster, SSH to the server and run:"
    echo "  ssh root@${first_server}"
    echo "  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml"
    echo "  export PATH=\$PATH:/var/lib/rancher/rke2/bin"
    echo "  kubectl get nodes"
    echo ""
    
    if [ "$SETUP_ARGOCD" = "true" ]; then
        log_info "ArgoCD is being deployed. To get the admin password:"
        echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
        echo ""
        log_info "Access ArgoCD at: https://argocd.virtualbox.local"
    fi
    
    log_info "Access Rancher at: https://virtualbox.local"
    log_info "Default Rancher password: admin"
    echo ""
    
    if [ "$SETUP_ARGOCD" = "true" ]; then
        log_info "Access Grafana at: https://grafana.virtualbox.local"
        log_info "Default Grafana credentials: admin/admin"
        echo ""
    fi
}

main() {
    local skip_jumpbox=false
    local skip_server=false
    local skip_agents=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -m|--machines)
                MACHINES_FILE="$2"
                shift 2
                ;;
            -a|--ha-mode)
                HA_MODE=true
                shift
                ;;
            --no-argocd)
                SETUP_ARGOCD=false
                shift
                ;;
            --skip-jumpbox)
                skip_jumpbox=true
                shift
                ;;
            --skip-server)
                skip_server=true
                shift
                ;;
            --skip-agents)
                skip_agents=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    log_info "Starting RKE2 cluster bootstrapping..."
    log_info "HA Mode: $HA_MODE"
    log_info "ArgoCD: $SETUP_ARGOCD"
    log_info "Machines file: $MACHINES_FILE"
    echo ""
    
    check_prerequisites
    
    if [ "$skip_jumpbox" = false ]; then
        setup_jumpbox
        configure_machine_hostnames
    fi
    
    if [ "$skip_server" = false ]; then
        # Setup server nodes
        local server_count=$(grep -c "server" "$MACHINES_FILE")
        local server_idx=0
        
        while read IP FQDN HOST SUBNET; do
            if [[ $HOST == server* ]]; then
                if [ $server_idx -eq 0 ]; then
                    setup_server_node "$HOST" true
                    # Wait a bit for the first server to be fully ready
                    sleep 30
                elif [ "$HA_MODE" = "true" ]; then
                    setup_server_node "$HOST" false
                    sleep 20
                fi
                server_idx=$((server_idx + 1))
            fi
        done < "$MACHINES_FILE"
    fi
    
    if [ "$skip_agents" = false ]; then
        # Setup agent nodes
        local node_idx=0
        while read IP FQDN HOST SUBNET; do
            if [[ $HOST == node-* ]]; then
                setup_agent_node "$HOST" "$node_idx"
                node_idx=$((node_idx + 1))
                sleep 10
            fi
        done < "$MACHINES_FILE"
    fi
    
    # Wait for cluster to stabilize
    log_info "Waiting for cluster to stabilize..."
    sleep 30
    
    verify_cluster
    print_access_info
}

# Run main function
main "$@"
