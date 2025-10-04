# RKE2 Cluster Bootstrapping

This repo provides a guide to bootstrapping an RKE2 ([Rancher Kubernetes Engine](https://docs.rke2.io/)) cluster with a few sensible defaults:

- Cilium CNI with WireGuard tunnelling, kube-proxy replacement and Hubble observability
- CSI compliance by default
- DNS NodeLocal Cache
- ServiceLB load balancer controller

You can try it out using VirtualBox. Please note that some practices presented here would be at least questionable in a production environment (limited host hardening, self-signed control plane certs), but were simplified since they will strongly differ depending on environment configuration.

## VM setup

Assuming you have VirtualBox installed:

- Download the latest `raw` Debian image in `nocloud` flavor: https://cloud.debian.org/images/cloud/

- Convert the image to VDI:

```shell
VBoxManage convertfromraw debian-12-nocloud-amd64-<REVISION>.raw  debian-12-nocloud-amd64-<REVISION>.vdi --format VDI
```

Create four VMs with the following resources (specs taken from the awesome [Kubernetes The Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way) project):

| Name    | Description            | CPU | RAM   | Storage |
|---------|------------------------|-----|-------|---------|
| jumpbox | Administration host    | 1   | 512MB | 10GB    |
| server  | Kubernetes server      | 1   | 4GB   | 20GB    |
| node-0  | Kubernetes worker node | 1   | 4GB   | 20GB    |
| node-1  | Kubernetes worker node | 1   | 4GB   | 20GB    |

- Do not specify an ISO image and use the VDI file as volume. Create a NAT network and attach a NAT-network interface to each VM. If you prefer not to use the VirtualBox terminal window, also attach a host-only interface to the jumpbox.

- Boot all machines, login as `root` with no password using the VirtualBox terminal. Configure SSH access on all machines:

```shell
apt-get update && apt-get install -y openssh-server && sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && systemctl daemon-reload && systemctl restart sshd && echo "root:toor" | chpasswd
```

- Edit the `misc/machines.txt` file and replace the first column with IPv4 addresses of server and nodes bound to NAT-network interfaces. Then, copy the file to the jumpbox and run the setup script:

```shell
JUMPBOX_IP=<JUMPBOX_HOSTONLY_IP>
scp vm/machines.txt vm/setup.sh root@$JUMPBOX_IP:/root/
ssh root@$JUMPBOX_IP bash setup.sh
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
```

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
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin/rke2/bin
```

Then:

```shell
kubectl version
kubectl cluster-info
kubectl get nodes
kubectl get pods --all-namespaces
```
