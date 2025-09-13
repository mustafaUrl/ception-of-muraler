#!/bin/bash
# K3D Cluster ve ArgoCD Setup Script (lujiangz buff xd)

set -e

# Renkler
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

ARGOCD_PORT=""
PORT_FORWARD_PID=""
ARGOCD_PASSWORD=""

# -----------------------------
# Yardımcı Fonksiyonlar
# -----------------------------
log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; exit 1; }

check_requirements() {
    log_info "Gerekli araçlar kontrol ediliyor ve kuruluyor..."

    # k3d kurulumu
    if ! command -v k3d &> /dev/null; then
        log_warn "k3d bulunamadı. Kuruluyor..."
        wget -q -O - https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
        log_success "k3d kuruldu."
    fi

    # kubectl kurulumu (Ubuntu 24.04 fixli)
    if ! command -v kubectl &> /dev/null; then
        log_warn "kubectl bulunamadı. Kuruluyor..."

        # Eski bozuk repo varsa temizle
        sudo rm -f /etc/apt/sources.list.d/kubernetes.list
        sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

        # Yeni repo ekle
        sudo apt-get update
        sudo apt-get install -y apt-transport-https ca-certificates curl gpg
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
            | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
            | sudo tee /etc/apt/sources.list.d/kubernetes.list

        sudo apt-get update
        sudo apt-get install -y kubectl
        log_success "kubectl kuruldu."
    fi

    # Docker yetki kontrolü ve düzenlemesi
    if ! docker info &> /dev/null; then
        if [[ $(id -Gn "$USER" | grep -c "docker") -eq 0 ]]; then
            log_warn "Docker daemon'a erişim yetkiniz yok. Kullanıcı '${USER}' docker grubuna ekleniyor..."
            sudo usermod -aG docker "$USER"
            log_success "Kullanıcı başarıyla docker grubuna eklendi."
            log_error "Yetkilerin geçerli olması için lütfen terminali kapatıp yeniden açın ve script'i tekrar çalıştırın."
        else
            log_error "Docker daemon çalışmıyor veya başka bir sorun var. Lütfen docker servisini kontrol edin."
        fi
    fi

    # argocd CLI kurulumu
    if ! command -v argocd &> /dev/null; then
        log_warn "argocd CLI bulunamadı. Kuruluyor..."
        VERSION=$(curl --silent "https://api.github.com/repos/argoproj/argo-cd/releases/latest" \
            | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
        sudo curl -sSL -o /usr/local/bin/argocd \
            https://github.com/argoproj/argo-cd/releases/download/$VERSION/argocd-linux-amd64
        sudo chmod +x /usr/local/bin/argocd
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
    k3d cluster create mycluster --servers 1 --agents 1 \
        -p "8080:80@loadbalancer" -p "8443:443@loadbalancer"
    log_success "K3D cluster oluşturuldu."
}

install_argocd() {
    log_info "ArgoCD kuruluyor..."
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
    log_success "ArgoCD kuruldu."
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

find_available_port() {
    local start=${1:-8081}
    for port in $(seq $start $((start+50))); do
        ! lsof -i :$port >/dev/null 2>&1 && echo $port && return 0
    done
    log_error "Boş port bulunamadı 8081-8131 arasında."
}

start_port_forward() {
    ARGOCD_PORT=$(find_available_port 8081)
    log_info "Port forwarding başlatılıyor... Port: $ARGOCD_PORT"
    kubectl wait --for=condition=Ready --timeout=300s pod -l app.kubernetes.io/name=argocd-server -n argocd
    kubectl port-forward svc/argocd-server -n argocd $ARGOCD_PORT:443 >/dev/null 2>&1 &
    PORT_FORWARD_PID=$!
    sleep 3
    if ! kill -0 $PORT_FORWARD_PID >/dev/null 2>&1; then
        log_error "Port forwarding başlatılamadı."
    fi
    log_success "Port forwarding başladı: https://localhost:$ARGOCD_PORT"
}

login_argocd() {
    log_info "ArgoCD'ye login oluyor..."
    if ! argocd login localhost:$ARGOCD_PORT --username admin --password "$ARGOCD_PASSWORD" --insecure; then
        log_error "ArgoCD login başarısız!"
    fi
    log_success "ArgoCD login başarılı."
}

add_repository() {
    log_info "GitHub repository ekleniyor..."
    if ! argocd repo add https://github.com/mustafaUrl/Inception-of-Things; then
        log_warn "Repo zaten ekli olabilir."
    else
        log_success "Repo eklendi."
    fi
}

create_application() {
    log_info "ArgoCD uygulaması oluşturuluyor..."
    if ! argocd app create my-app \
        --repo https://github.com/mustafaUrl/Inception-of-Things \
        --path p3/manifests \
        --dest-server https://kubernetes.default.svc \
        --dest-namespace dev; then
        log_warn "Uygulama zaten var olabilir."
    else
        log_success "Uygulama oluşturuldu."
    fi
}

sync_application() {
    log_info "Uygulama sync ediliyor..."
    argocd app sync my-app
    log_success "Uygulama sync edildi."
}

cleanup() {
    [[ -n "$PORT_FORWARD_PID" ]] && kill $PORT_FORWARD_PID 2>/dev/null
}

trap cleanup EXIT

reset_system() {
    pkill -f "kubectl port-forward.*argocd-server" || true
    k3d cluster delete mycluster || true
    rm -rf "$HOME/.argocd"
    log_success "Sistem sıfırlandı."
}

setup_system() {
    check_requirements
    create_k3d_cluster
    install_argocd

    log_info "ArgoCD resource.exclusions kaldırılıyor ve sunucu yeniden başlatılıyor..."
    kubectl patch configmap argocd-cm -n argocd --type='json' -p='[{"op": "remove", "path": "/data/resource.exclusions"}]' 2>/dev/null || echo -e "${YELLOW}ℹ️  resource.exclusions zaten mevcut değil${NC}"
    kubectl rollout restart deployment argocd-server -n argocd
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
    log_success "ArgoCD sunucusu yeniden başlatıldı."

    create_dev_namespace
    get_argocd_password
    start_port_forward
    login_argocd
    add_repository
    create_application
    sync_application

    log_info "my-app-deployment'in hazır olması bekleniyor..."
    kubectl wait --for=condition=available --timeout=300s deployment/my-app-deployment -n dev
    log_success "my-app-deployment hazır."

    log_info "Uygulama için port-forward başlatılıyor (8888 -> 80)..."
    nohup kubectl port-forward svc/my-app-service -n dev 8888:80 > /dev/null 2>&1 &

    log_success "Kurulum tamamlandı! ArgoCD UI: https://localhost:$ARGOCD_PORT"
    log_success "Uygulamanız artık http://localhost:8888 adresinde erişilebilir."
    log_warn "İlk admin şifreniz: $ARGOCD_PASSWORD"
    log_warn "Güvenliğiniz için lütfen ilk girişte şifrenizi değiştirin."
    wait
}

main() {
    case "${1:-setup}" in
        setup|-s|--setup) setup_system ;;
        reset|-r|--reset) reset_system ;;
        help|-h|--help) echo "Kullanım: $0 [setup|reset|help]" ;;
        *) log_error "Bilinmeyen seçenek: $1" ;;
    esac
}

main "$@"
