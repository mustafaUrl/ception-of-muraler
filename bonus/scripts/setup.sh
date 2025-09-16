#!/bin/bash
# K3D Cluster, ArgoCD, and GitLab Setup Script (lujiangz is crying)

set -e

# Renkler
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

ARGOCD_PORT="8081"
ARGOCD_PASSWORD=""
GITLAB_PASSWORD=""
GITLAB_URL="http://gitlab.127.0.0.1.nip.io:8080"
GITLAB_PROJECT_URL="http://gitlab.127.0.0.1.nip.io:8080/root/inception-of-things.git"

# -----------------------------
# Yardımcı Fonksiyonlar
# -----------------------------
log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; exit 1; }

check_requirements() {
    log_info "Gerekli araçlar kontrol ediliyor ve kuruluyor..."

    # Docker
    if ! command -v docker &> /dev/null; then
        log_warn "Docker bulunamadı. Kuruluyor..."
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo usermod -aG docker vagrant
        log_warn "Docker kuruldu. İzinlerin geçerli olması için 'vagrant reload' gerekebilir."
    fi

    # k3d
    if ! command -v k3d &> /dev/null; then
        log_warn "k3d bulunamadı. Kuruluyor..."
        wget -q -O - https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
        log_success "k3d kuruldu."
    fi

    # kubectl
    if ! command -v kubectl &> /dev/null; then
        log_warn "kubectl bulunamadı. Kuruluyor..."
        sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gpg
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
        sudo apt-get update && sudo apt-get install -y kubectl
        log_success "kubectl kuruldu."
    fi

    # helm
    if ! command -v helm &> /dev/null; then
        log_warn "helm bulunamadı. Kuruluyor..."
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        log_success "helm kuruldu."
    fi
    
    # git
    if ! command -v git &> /dev/null; then
        log_warn "git bulunamadı. Kuruluyor..."
        sudo apt-get update && sudo apt-get install -y git
        log_success "git kuruldu."
    fi

    # argocd CLI
    if ! command -v argocd &> /dev/null; then
        log_warn "argocd CLI bulunamadı. Kuruluyor..."
        VERSION=$(curl --silent "https://api.github.com/repos/argoproj/argo-cd/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
        sudo curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/download/$VERSION/argocd-linux-amd64
        sudo chmod +x /usr/local/bin/argocd
        log_success "argocd CLI kuruldu."
    fi

    log_success "Tüm gereksinimler karşılandı."
}

create_k3d_cluster() {
    log_info "K3D cluster oluşturuluyor..."
    if sudo k3d cluster list | grep -q "mycluster"; then
        log_warn "mycluster zaten var. Siliniyor..."
        sudo k3d cluster delete mycluster
    fi
    sudo k3d cluster create mycluster --servers 1 --agents 1 -p "8080:80@loadbalancer" -p "8443:443@loadbalancer"
    log_success "K3D cluster oluşturuldu."
}

install_argocd() {
    log_info "ArgoCD kuruluyor..."
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd
    log_success "ArgoCD kuruldu."
}

create_namespaces() {
    log_info "'dev' ve 'gitlab' namespace'leri oluşturuluyor..."
    kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace gitlab --dry-run=client -o yaml | kubectl apply -f -
    log_success "Namespace'ler oluşturuldu."
}

install_gitlab() {
    log_info "GitLab Helm chart deposu ekleniyor..."
    helm repo add gitlab https://charts.gitlab.io/
    helm repo update

    log_info "GitLab kuruluyor (bu işlem uzun sürebilir)..."
    helm upgrade --install gitlab gitlab/gitlab \
      -n gitlab \
      -f /vagrant/confs/values.yaml \
      --timeout 1800s
    
    log_info "GitLab podlarının hazır olması bekleniyor..."
    kubectl wait --for=condition=available --timeout=1800s deployment -l app.kubernetes.io/name=gitlab -n gitlab
    log_success "GitLab kuruldu."
}

get_passwords() {
    log_info "ArgoCD ve GitLab şifreleri alınıyor..."
    until kubectl -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; do sleep 5; done
    ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
    
    until kubectl -n gitlab get secret gitlab-gitlab-initial-root-password >/dev/null 2>&1; do sleep 5; done
    GITLAB_PASSWORD=$(kubectl -n gitlab get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 --decode)
    
    log_success "Şifreler başarıyla alındı."
}

login_argocd() {
    log_info "ArgoCD'ye login oluyor..."
    # Port forwarding is handled by Vagrantfile
    kubectl port-forward svc/argocd-server -n argocd 8081:443 > /dev/null 2>&1 &
    sleep 15 # give port-forward time to start
    argocd login localhost:8081 --username admin --password "$ARGOCD_PASSWORD" --insecure
    log_success "ArgoCD login başarılı."
}

setup_gitlab_project() {
    log_info "Waiting for GitLab to be ready..."
    until curl -s -k --head --fail "$GITLAB_URL/users/sign_in"; do
        log_info "GitLab is not ready yet, waiting..."
        sleep 10
    done

    log_info "Creating GitLab project 'inception-of-things'..."
    CREATE_PROJECT_RESPONSE=$(curl -s -k --request POST "$GITLAB_URL/api/v4/projects" \
        --header "PRIVATE-TOKEN: $GITLAB_PASSWORD" \
        --data "name=inception-of-things&visibility=public")

    if echo "$CREATE_PROJECT_RESPONSE" | grep -q '"message":{"name":["has already been taken"]}'; then
        log_warn "Project 'inception-of-things' already exists."
    else
        log_success "Project 'inception-of-things' created."
    fi

    log_info "Pushing manifests to GitLab..."
    TEMP_DIR=$(mktemp -d)
    git clone "$GITLAB_PROJECT_URL" "$TEMP_DIR"
    cp -r /vagrant/p3/manifests/* "$TEMP_DIR/"
    cd "$TEMP_DIR"
    git config --global user.email "admin@example.com"
    git config --global user.name "Admin"
    git add .
    git commit -m "Initial commit of manifests"
    git push http://root:$GITLAB_PASSWORD@gitlab.127.0.0.1.nip.io:8080/root/inception-of-things.git
    cd -
    rm -rf "$TEMP_DIR"
    log_success "Manifests pushed to GitLab."
}

add_repo_to_argocd() {
    log_info "Yerel GitLab deposu ArgoCD'ye ekleniyor..."
    argocd repo add $GITLAB_PROJECT_URL --username root --password "$GITLAB_PASSWORD" --insecure
    log_success "Yerel GitLab deposu eklendi."
}

create_application() {
    log_info "ArgoCD uygulaması oluşturuluyor..."
    argocd app create my-app \
        --repo $GITLAB_PROJECT_URL \
        --path manifests \
        --dest-server https://kubernetes.default.svc \
        --dest-namespace dev \
        --sync-policy automated
    log_success "Uygulama oluşturuldu."
}

sync_application() {
    log_info "Uygulama sync ediliyor..."
    argocd app sync my-app
    log_success "Uygulama sync edildi."
}

reset_system() {
    pkill -f "kubectl port-forward" || true
    sudo k3d cluster delete mycluster || true
    rm -rf "$HOME/.argocd"
    log_success "Sistem sıfırlandı."
}

setup_system() {
    check_requirements
    create_k3d_cluster
    install_argocd
    create_namespaces
    install_gitlab
    
    get_passwords
    login_argocd
    
    setup_gitlab_project
    
    add_repo_to_argocd
    create_application
    sync_application

    log_info "my-app-deployment'in hazır olması bekleniyor..."
    kubectl wait --for=condition=available --timeout=300s deployment/my-app-deployment -n dev
    log_success "my-app-deployment hazır."

    log_info "Uygulama için port-forward başlatılıyor (8888 -> 80)..."
    nohup kubectl port-forward svc/my-app-service -n dev 8888:80 > /dev/null 2>&1 &

    log_success "Kurulum tamamlandı!"
    log_info "ArgoCD UI: https://localhost:8081 (user: admin, pass: $ARGOCD_PASSWORD)"
    log_info "GitLab UI: $GITLAB_URL (user: root, pass: $GITLAB_PASSWORD)"
    log_info "Uygulamanız: http://localhost:8888"
    
    wait
}

main() {
    case "${1:-setup}" in
        setup|-s|--setup) setup_system ;; \
        reset|-r|--reset) reset_system ;; \
        help|-h|--help) echo "Kullanım: $0 [setup|reset|help]" ;; \
        *) log_error "Bilinmeyen seçenek: $1" ;; 
    esac
}

main "$@"