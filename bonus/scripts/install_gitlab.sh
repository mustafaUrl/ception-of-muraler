#!/bin/bash
set -e

# Paket güncelleme
sudo apt-get update -y
sudo apt-get upgrade -y

# Gerekli paketler
sudo apt-get install -y curl openssh-server ca-certificates tzdata perl

# Gitlab repo ekle
curl https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | sudo bash

# Gitlab Community Edition kur
sudo EXTERNAL_URL="http://localhost" apt-get install -y gitlab-ce
