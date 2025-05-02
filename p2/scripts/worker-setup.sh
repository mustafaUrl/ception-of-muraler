#!/bin/bash

sudo apt update -y && sudo apt upgrade -y

TOKEN_PATH="/vagrant/node-token"

while [ ! -f "$TOKEN_PATH" ]; do
  echo "Waiting for node-token from master..."
  sleep 2
done

NODE_TOKEN=$(cat /vagrant/node-token)
MASTER_IP="192.168.56.110"


curl -sfL https://get.k3s.io | K3S_URL="https://$MASTER_IP:6443" K3S_TOKEN="$NODE_TOKEN" INSTALL_K3S_EXEC="--node-ip=192.168.56.111" sh -

