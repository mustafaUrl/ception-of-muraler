#!/bin/bash


sudo apt update -y && sudo apt upgrade -y

sudo curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--node-ip=192.168.56.110" sh -

cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token
