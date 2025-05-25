#!/bin/bash


sudo apt update -y && sudo apt upgrade -y

sudo curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode=644" sh -

# sudo kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/baremetal/deploy.yaml

cp /vagrant/confs/* /home/vagrant/

mkdir -p /home/vagrant/.kube
cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config

kubectl create -f /home/vagrant/deployment.yaml -f /home/vagrant/service.yaml -f /home/vagrant/ingress.yaml

echo "192.168.56.110 app1.com" | sudo tee -a "/etc/hosts"
echo "192.168.56.110 app2.com" | sudo tee -a "/etc/hosts"
echo "192.168.56.110 app3.com" | sudo tee -a "/etc/hosts"