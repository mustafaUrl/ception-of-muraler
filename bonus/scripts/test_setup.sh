#!/bin/bash
# K3D Cluster, ArgoCD ve GitLab Setup Script (Sudo-free for Vagrant)

set -e

# Renkler
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

ARGOCD_PORT=""
GITLAB_PORT=""
PORT_FORWARD_PID=""
GITLAB_FORWARD_PID=""
ARGOCD_PASSWORD=""

# -----------------------------
# Yardımcı Fonksiyonlar
# -----------------------------
log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; exit 1; }

setup_docker_rootless() {
    log_info "Docker rootless mode kurulumu kontrol ediliyor..."
    
    # Rootless mode için gerekli paketleri kontrol et
    if ! command -v dockerd-rootless-setuptool.sh &> /dev/null; then
        log_warn "Docker rootless araçları bulunamadı. Yükleniyor..."
        
        # Ubuntu/Debian için rootless araçları yükle
        if command -v apt &> /dev/null; then
            sudo apt-get update
            sudo apt-get install -y docker-ce-rootless-extras
        fi
    fi
    
    # Rootless mode'u kur
    if ! systemctl --user is-active docker >/dev/null 2>&1; then
        log_info "Docker rootless mode kuruluyor..."
        
        # Sistem docker'ını durdur
        sudo systemctl stop docker docker.socket 2>/dev/null || true
        sudo systemctl disable docker docker.socket 2>/dev/null || true
        
        # Rootless mode'u başlat
        export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock
        echo 'export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock' >> ~/.bashrc
        
        dockerd-rootless-setuptool.sh install
        systemctl --user start docker
        systemctl --user enable docker
        
        log_success "Docker rootless mode kuruldu."
    else
        export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock
        log_success "Docker rootless mode zaten aktif."
    fi
}

check_requirements() {
    log_info "Gerekli araçlar kontrol ediliyor ve kuruluyor..."
    
    # Temel dizinleri oluştur
    mkdir -p ~/.local/bin
    export PATH="$HOME/.local/bin:$PATH"
    
    # PATH'i kalıcı yap
    if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
    fi

    # Docker kurulumu ve yapılandırması
    install_docker
    
    # Docker rootless mode denemeyi de ekleyelim (opsiyonel)
    # setup_docker_rootless

    # k3d kurulumu
    if ! command -v k3d &> /dev/null; then
        log_warn "k3d bulunamadı. Kuruluyor..."
        wget -q -O - https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
        log_success "k3d kuruldu."
    fi

    # kubectl kurulumu
    if ! command -v kubectl &> /dev/null; then
        log_warn "kubectl bulunamadı. Kuruluyor..."
        
        # kubectl binary'yi kullanıcı dizinine indir
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x kubectl
        mv kubectl ~/.local/bin/
        log_success "kubectl kuruldu."
    fi

    # helm kurulumu
    if ! command -v helm &> /dev/null; then
        log_warn "helm bulunamadı. Kuruluyor..."
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        # Helm'i kullanıcı dizinine taşı
        if [ -f "/usr/local/bin/helm" ] && [ ! -f "$HOME/.local/bin/helm" ]; then
            cp /usr/local/bin/helm ~/.local/bin/ 2>/dev/null || sudo cp /usr/local/bin/helm ~/.local/bin/
        fi
        log_success "helm kuruldu."
    fi

    # argocd CLI kurulumu
    if ! command -v argocd &> /dev/null; then
        log_warn "argocd CLI bulunamadı. Kuruluyor..."
        VERSION=$(curl --silent "https://api.github.com/repos/argoproj/argo-cd/releases/latest" \
            | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
        curl -sSL -o ~/.local/bin/argocd \
            https://github.com/argoproj/argo-cd/releases/download/$VERSION/argocd-linux-amd64
        chmod +x ~/.local/bin/argocd
        log_success "argocd CLI kuruldu."
    fi

    log_success "Tüm gereksinimler karşılandı."
}

create_k3d_cluster() {
    log_info "K3D cluster oluşturuluyor..."
    if k3d cluster list | grep -q "mycluster"; then
        log_warn "mycluster zaten var. Siliniyor..."
        k3d cluster delete mycluster
    fi
    k3d cluster create mycluster --servers 1 --agents 2 \
        -p "8080:80@loadbalancer" -p "8443:443@loadbalancer" \
        -p "9080:9080@loadbalancer"
    log_success "K3D cluster oluşturuldu."
}

install_argocd() {
    log_info "ArgoCD kuruluyor..."
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
    log_success "ArgoCD kuruldu."
}

install_gitlab() {
    log_info "GitLab Helm repository ekleniyor..."
    helm repo add gitlab https://charts.gitlab.io/
    helm repo update
    
    log_info "GitLab namespace oluşturuluyor..."
    kubectl create namespace gitlab --dry-run=client -o yaml | kubectl apply -f -
    
    log_info "GitLab kuruluyor (bu işlem 5-10 dakika sürebilir)..."
    
    # GitLab için özel values dosyası oluştur
    cat > /tmp/gitlab-values.yaml << EOF
global:
  hosts:
    domain: gitlab.local
    externalIP: 127.0.0.1
  ingress:
    enabled: false
  
gitlab:
    webservice:
      service:
        type: NodePort
        nodePort: 9080
    
postgresql:
  install: true
  
redis:
  install: true
  
registry:
  enabled: false
  
gitlab-runner:
  install: false
  
prometheus:
  install: false
  
grafana:
  enabled: false
  
certmanager:
  install: false
  
nginx-ingress:
  enabled: false
  
minio:
  persistence:
    size: 1Gi
EOF

    helm install gitlab gitlab/gitlab \
        --namespace gitlab \
        --values /tmp/gitlab-values.yaml \
        --set global.edition=ce \
        --set certmanager-issuer.email=admin@gitlab.local \
        --timeout=600s
    
    log_info "GitLab podların hazır olması bekleniyor..."
    kubectl wait --for=condition=Ready --timeout=600s pod -l app=webservice -n gitlab
    
    log_success "GitLab kuruldu."
}

create_dev_namespace() {
    log_info "'dev' namespace oluşturuluyor..."
    kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -
    log_success "'dev' namespace oluşturuldu."
}

get_argocd_password() {
    log_info "ArgoCD admin şifresi alınıyor..."
    until kubectl -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; do sleep 5; done
    ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    log_success "Admin şifresi başarıyla alındı."
}

get_gitlab_password() {
    log_info "GitLab root şifresi alınıyor..."
    until kubectl -n gitlab get secret gitlab-gitlab-initial-root-password >/dev/null 2>&1; do sleep 5; done
    GITLAB_PASSWORD=$(kubectl -n gitlab get secret gitlab-gitlab-initial-root-password -o jsonpath="{.data.password}" | base64 -d)
    log_success "GitLab root şifresi alındı."
}

find_available_port() {
    local start=${1:-8081}
    for port in $(seq $start $((start+50))); do
        ! lsof -i :$port >/dev/null 2>&1 && echo $port && return 0
    done
    log_error "Boş port bulunamadı $start-$((start+50)) arasında."
}

start_port_forward() {
    ARGOCD_PORT=$(find_available_port 8081)
    log_info "ArgoCD Port forwarding başlatılıyor... Port: $ARGOCD_PORT"
    kubectl wait --for=condition=Ready --timeout=300s pod -l app.kubernetes.io/name=argocd-server -n argocd
    kubectl port-forward svc/argocd-server -n argocd $ARGOCD_PORT:443 >/dev/null 2>&1 &
    PORT_FORWARD_PID=$!
    sleep 3
    if ! kill -0 $PORT_FORWARD_PID >/dev/null 2>&1; then
        log_error "ArgoCD Port forwarding başlatılamadı."
    fi
    log_success "ArgoCD Port forwarding başladı: https://localhost:$ARGOCD_PORT"
}

start_gitlab_port_forward() {
    GITLAB_PORT=$(find_available_port 9081)
    log_info "GitLab Port forwarding başlatılıyor... Port: $GITLAB_PORT"
    kubectl wait --for=condition=Ready --timeout=300s pod -l app=webservice -n gitlab
    kubectl port-forward svc/gitlab-webservice-default -n gitlab $GITLAB_PORT:8080 >/dev/null 2>&1 &
    GITLAB_FORWARD_PID=$!
    sleep 3
    if ! kill -0 $GITLAB_FORWARD_PID >/dev/null 2>&1; then
        log_error "GitLab Port forwarding başlatılamadı."
    fi
    log_success "GitLab Port forwarding başladı: http://localhost:$GITLAB_PORT"
}

login_argocd() {
    log_info "ArgoCD'ye login oluyor..."
    if ! argocd login localhost:$ARGOCD_PORT --username admin --password "$ARGOCD_PASSWORD" --insecure; then
        log_error "ArgoCD login başarısız!"
    fi
    log_success "ArgoCD login başarılı."
}

setup_gitlab_repo() {
    log_info "GitLab'da örnek repository oluşturmak için talimatlar:"
    log_warn "1. GitLab'a giriş yapın: http://localhost:$GITLAB_PORT"
    log_warn "2. Kullanıcı: root, Şifre: $GITLAB_PASSWORD"
    log_warn "3. 'my-k8s-app' adında bir proje oluşturun"
    log_warn "4. Kubernetes manifest dosyalarınızı yükleyin"
}

add_gitlab_repository() {
    log_info "GitLab repository ArgoCD'ye ekleniyor..."
    # GitLab'ın cluster içindeki servis adresini kullan
    GITLAB_INTERNAL_URL="http://gitlab-webservice-default.gitlab.svc.cluster.local:8080"
    
    log_warn "GitLab repository'yi manuel olarak eklemeniz gerekecek:"
    log_warn "ArgoCD UI'da Settings > Repositories > Connect Repo"
    log_warn "URL: $GITLAB_INTERNAL_URL/root/my-k8s-app.git"
    log_warn "Veya external URL: http://localhost:$GITLAB_PORT/root/my-k8s-app.git"
}

create_sample_manifests() {
    log_info "Örnek Kubernetes manifest dosyaları oluşturuluyor..."
    
    mkdir -p /tmp/k8s-manifests
    
    cat > /tmp/k8s-manifests/deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app-deployment
  namespace: dev
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
      - name: nginx
        image: nginx:1.21
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: my-app-service
  namespace: dev
spec:
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
EOF

    log_success "Örnek manifest dosyaları /tmp/k8s-manifests/ dizininde oluşturuldu."
    log_info "Bu dosyaları GitLab repository'nize yükleyin."
}

cleanup() {
    [[ -n "$PORT_FORWARD_PID" ]] && kill $PORT_FORWARD_PID 2>/dev/null
    [[ -n "$GITLAB_FORWARD_PID" ]] && kill $GITLAB_FORWARD_PID 2>/dev/null
}

trap cleanup EXIT

reset_system() {
    pkill -f "kubectl port-forward.*argocd-server" || true
    pkill -f "kubectl port-forward.*gitlab" || true
    k3d cluster delete mycluster || true
    rm -rf "$HOME/.argocd"
    rm -rf /tmp/k8s-manifests
    rm -rf /tmp/gitlab-values.yaml
    log_success "Sistem sıfırlandı."
}

setup_system() {
    check_requirements
    create_k3d_cluster
    install_argocd
    install_gitlab

    log_info "ArgoCD resource.exclusions kaldırılıyor ve sunucu yeniden başlatılıyor..."
    kubectl patch configmap argocd-cm -n argocd --type='json' -p='[{"op": "remove", "path": "/data/resource.exclusions"}]' 2>/dev/null || echo -e "${YELLOW}ℹ️  resource.exclusions zaten mevcut değil${NC}"
    kubectl rollout restart deployment argocd-server -n argocd
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
    log_success "ArgoCD sunucusu yeniden başlatıldı."

    create_dev_namespace
    get_argocd_password
    get_gitlab_password
    start_port_forward
    start_gitlab_port_forward
    login_argocd
    create_sample_manifests
    setup_gitlab_repo
    add_gitlab_repository

    log_success "Kurulum tamamlandı!"
    log_success "ArgoCD UI: https://localhost:$ARGOCD_PORT (admin / $ARGOCD_PASSWORD)"
    log_success "GitLab UI: http://localhost:$GITLAB_PORT (root / $GITLAB_PASSWORD)"
    log_warn "GitLab'a giriş yapıp 'my-k8s-app' repository'si oluşturun ve manifest dosyalarını yükleyin."
    log_warn "Ardından ArgoCD'de bu repository'yi ekleyip uygulama oluşturun."
    
    wait
}

main() {
    case "${1:-setup}" in
        setup|-s|--setup) setup_system ;;
        reset|-r|--reset) reset_system ;;
        help|-h|--help) 
            echo "Kullanım: $0 [setup|reset|help]"
            echo "  setup: K3D cluster, ArgoCD ve GitLab kurulumunu yapar"
            echo "  reset: Tüm bileşenleri siler ve temizler"
            echo "  help:  Bu yardım mesajını gösterir"
            ;;
        *) log_error "Bilinmeyen seçenek: $1" ;;
    esac
}

main "$@"