#!/bin/bash


sudo apt update -y && sudo apt upgrade -y

sudo curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--node-ip=192.168.56.110 --write-kubeconfig-mode=644" sh -

cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token


USER_HOME="/home/vagrant"


if [ -d "$USER_HOME" ]; then
  sudo mkdir -p $USER_HOME/.kube
  sudo cp /etc/rancher/k3s/k3s.yaml $USER_HOME/.kube/config
  sudo chown -R vagrant:vagrant $USER_HOME/.kube

  echo "export KUBECONFIG=$USER_HOME/.kube/config" >> $USER_HOME/.bashrc
  echo "alias k='kubectl'" >> $USER_HOME/.bashrc
fi