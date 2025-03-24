#!/bin/bash

set -e

echo "[INFO] K3s Master Node kurulumu başlatılıyor..."

# Firewall devre dışı bırakılıyor (isteğe bağlı)
# systemctl disable --now firewalld

# K3s Server kurulumu
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable servicelb --disable traefik" sh -

# Token dosyasını Vagrant paylaşım klasörüne kopyala (worker node’ların erişebilmesi için)
cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token

# Kurulum tamamlandı
echo "[INFO] K3s Master Node kurulumu tamamlandı. Token dosyası /vagrant/node-token içine kopyalandı."
