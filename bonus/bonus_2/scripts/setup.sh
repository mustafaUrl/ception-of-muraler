#!/bin/bash

set -e

# Create a k3d cluster
if ! k3d cluster list | grep -q 'gitlab-cluster'; then
    k3d cluster create gitlab-cluster -p "80:80@loadbalancer" -p "443:443@loadbalancer" --agents 1
fi

# Create gitlab namespace
kubectl create namespace gitlab --dry-run=client -o yaml | kubectl apply -f -

# Add GitLab Helm repository
helm repo add gitlab https://charts.gitlab.io/
helm repo update

# Install GitLab
helm install gitlab gitlab/gitlab \
  --namespace gitlab \
  --timeout 600s \
  -f ../confs/values.yaml

echo "GitLab installation started. It may take a while."
echo "Check the status with: kubectl get pods -n gitlab"
