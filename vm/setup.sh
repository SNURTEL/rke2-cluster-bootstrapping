#!/bin/bash

# Run this script on the jumpbox VM

set -euxo pipefail

echo "deb http://ftp.de.debian.org/debian/ bookworm main non-free-firmware non-free contrib" >> /etc/apt/sources.list
echo "deb http://ftp.de.debian.org/debian/ bookworm-updates main non-free-firmware non-free contrib" >> /etc/apt/sources.list
echo "deb http://ftp.de.debian.org/debian-security/ bookworm-security main non-free-firmware non-free contrib" >> /etc/apt/sources.list

apt-get update && apt-get install -y wget curl vim openssl git sshpass

while read IP FQDN HOST SUBNET; do
  ENTRY="${IP} ${FQDN} ${HOST}"
  echo $ENTRY >> /etc/hosts
done < machines.txt

ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -P ""

while read IP FQDN HOST SUBNET; do
  # distribute the ssh key to each machine
  sshpass -p toor ssh-copy-id -o StrictHostKeyChecking=no root@${IP}
  ssh -n root@${HOST} hostname

  CMD="sed -i 's/^127.0.1.1.*/127.0.1.1\t${FQDN} ${HOST}/' /etc/hosts"
  ssh -n root@${HOST} "$CMD"
  ssh -n root@${HOST} hostnamectl set-hostname ${HOST}
  ssh -n root@${HOST} systemctl restart systemd-hostnamed
  ssh -n root@${HOST} hostname --fqdn

  scp hosts root@${HOST}:~/
  ssh -n root@${HOST} "cat hosts >> /etc/hosts"

  echo "PS1='\[\033[02;36m\][\u@\h:\[\033[02;33m\]\w]\$\[\033[00m\] '" >> /root/.bashrc
done < machines.txt

