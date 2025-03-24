#!/bin/bash
echo "Başlatılıyor: Worker Node Kurulumu"

# Güncellemeler ve bağımlı paketler
echo "Güncellemeler yapılıyor..."
sudo apt update -y
sudo apt install -y curl openssh-client

# Master Node'dan Node Token'ı al
echo "Node token bekleniyor..."
while [ ! -f /home/vagrant/node-token ]; do
  sleep 5
done

NODE_TOKEN=$(cat /home/vagrant/node-token)
MASTER_IP="192.168.33.10"

# Worker Node olarak K3s'e katıl
echo "Worker Node K3s'e ekleniyor..."
curl -sfL https://get.k3s.io | K3S_URL="https://$MASTER_IP:6443" K3S_TOKEN="$NODE_TOKEN" sh -


# #!/bin/bash
# echo "Başlatılıyor: Worker Node Kurulumu"

# # Güncellemeler ve bağımlı paketler
# echo "Güncellemeler yapılıyor..."
# sudo apt update -y
# sudo apt install -y curl openssh-client sshpass

# # Master Node'dan Node Token'ı çek
# MASTER_IP="192.168.33.10"
# USER="vagrant"

# echo "Master Node'dan Node Token çekiliyor..."
# sshpass -p "vagrant" scp -o StrictHostKeyChecking=no $USER@$MASTER_IP:/var/lib/rancher/k3s/server/node-token /home/vagrant/node-token

# NODE_TOKEN=$(cat /home/vagrant/node-token)

# # Worker Node olarak K3s'e katıl
# echo "Worker Node K3s'e ekleniyor..."
# curl -sfL https://get.k3s.io | K3S_URL="https://$MASTER_IP:6443" K3S_TOKEN="$NODE_TOKEN" sh -
