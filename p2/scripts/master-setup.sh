#!/bin/bash


sudo apt update -y && sudo apt upgrade -y

sudo curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--node-ip=192.168.56.110 --write-kubeconfig-mode=644" sh -

# sudo kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/baremetal/deploy.yaml

cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token

cp /vagrant/config/* /home/vagrant/

mkdir -p /home/vagrant/.kube
cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
