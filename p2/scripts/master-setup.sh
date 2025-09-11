#!/bin/bash


sudo apt update -y && sudo apt upgrade -y

sudo curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode=644" sh -

# sudo kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/baremetal/deploy.yaml

cp /vagrant/confs/* /home/vagrant/

mkdir -p /home/vagrant/.kube
cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config

kubectl create -f /home/vagrant/deployment.yaml -f /home/vagrant/service.yaml -f /home/vagrant/ingress.yaml

USER_HOME="/home/vagrant"


if [ -d "$USER_HOME" ]; then
  sudo mkdir -p $USER_HOME/.kube
  sudo cp /etc/rancher/k3s/k3s.yaml $USER_HOME/.kube/config
  sudo chown -R vagrant:vagrant $USER_HOME/.kube

  echo "export KUBECONFIG=$USER_HOME/.kube/config" >> $USER_HOME/.bashrc
  echo "alias k='kubectl'" >> $USER_HOME/.bashrc
fi