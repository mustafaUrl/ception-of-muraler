#!/bin/bash

# K3D Cluster, ArgoCD ve GitLab Tam Otomatik Setup Script
# Bu script k3d cluster oluşturur, GitLab'ı kurar, yerel manifestleri GitLab'a push'lar ve ArgoCD'yi yapılandırır.

# ===================================================================================
# --- YAPILANDIRMA ---
# Manifest dosyalarınızın bulunduğu dizin. Script bu dizini GitLab'a gönderecek.
MANIFESTS_PATH="../confs/manifests"

# GitLab root kullanıcısı için sabit ve kalıcı bir şifre belirleyin.
# Bu şifre hem UI girişi hem de API işlemleri için kullanılacak.
# ÖNEMLİ: Güvenlik için bu şifreyi daha karmaşık bir şeyle değiştirebilirsiniz.
GITLAB_FIXED_ROOT_PASSWORD="SuperSecretPassword123!"
# --- /YAPILANDIRMA ---
# ===================================================================================

# Global Değişkenler
ARGOCD_PORT=""
GITLAB_PORT=""
PORT_FORWARD_PID=""
GITLAB_PASSWORD=""
set -e  # Hata durumunda scripti durdur

# Renkli output için
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Gerekli araçları kontrol et
check_requirements() {
    echo -e "${BLUE}📋 Gerekli araçlar kontrol ediliyor...${NC}"
    
    command -v k3d >/dev/null 2>&1 || { echo -e "${RED}❌ k3d bulunamadı. Lütfen k3d'yi kurun.${NC}"; exit 1; }
    command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}❌ kubectl bulunamadı. Lütfen kubectl'i kurun.${NC}"; exit 1; }
    command -v docker >/dev/null 2>&1 || { echo -e "${RED}❌ Docker bulunamadı. Lütfen Docker'ı kurun.${NC}"; exit 1; }
    command -v git >/dev/null 2>&1 || { echo -e "${RED}❌ git bulunamadı. Lütfen git'i kurun.${NC}"; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo -e "${RED}❌ jq bulunamadı. Lütfen jq'yu kurun (JSON işlemek için gerekli).${NC}"; exit 1; }
    
    if ! command -v argocd &> /dev/null; then
        echo -e "${YELLOW}⚠️  argocd CLI bulunamadı. ArgoCD CLI kurulacak...${NC}"
        install_argocd_cli
    fi
    
    echo -e "${GREEN}✅ Tüm gereksinimler karşılandı.${NC}"
}

# ArgoCD CLI kurulumu
install_argocd_cli() {
    echo -e "${BLUE}⬇️  ArgoCD CLI kuruluyor...${NC}"
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) echo -e "${RED}❌ Desteklenmeyen mimari: $ARCH${NC}"; exit 1 ;;
    esac
    ARGOCD_VERSION=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
    echo -e "${BLUE}📥 ArgoCD CLI $ARGOCD_VERSION indiriliyor...${NC}"
    sudo curl -sSL -o /usr/local/bin/argocd "https://github.com/argoproj/argo-cd/releases/download/$ARGOCD_VERSION/argocd-$OS-$ARCH"
    sudo chmod +x /usr/local/bin/argocd
    echo -e "${GREEN}✅ ArgoCD CLI kuruldu: $ARGOCD_VERSION${NC}"
}

# GitLab kurulumu
install_gitlab() {
    echo -e "${BLUE}🦊 GitLab Community Edition kuruluyor...${NC}"
    GITLAB_HTTP_PORT=$(find_available_port 8090)
    GITLAB_HTTPS_PORT=$(find_available_port 8443)
    GITLAB_SSH_PORT=$(find_available_port 8022)
    echo -e "${GREEN}✅ GitLab portları: HTTP=$GITLAB_HTTP_PORT, HTTPS=$GITLAB_HTTPS_PORT, SSH=$GITLAB_SSH_PORT${NC}"
    
    echo -e "${BLUE}🐳 GitLab Docker container, sabit root şifresi ile kuruluyor...${NC}"
    docker stop gitlab 2>/dev/null || true
    docker rm gitlab 2>/dev/null || true
    
    docker run -d \
        --name gitlab \
        --hostname gitlab.localhost \
        -e GITLAB_ROOT_PASSWORD="$GITLAB_FIXED_ROOT_PASSWORD" \
        -p $GITLAB_HTTP_PORT:80 \
        -p $GITLAB_HTTPS_PORT:443 \
        -p $GITLAB_SSH_PORT:22 \
        --volume gitlab-config:/etc/gitlab \
        --volume gitlab-logs:/var/log/gitlab \
        --volume gitlab-data:/var/opt/gitlab \
        --restart unless-stopped \
        gitlab/gitlab-ce:latest
        
    GITLAB_PORT=$GITLAB_HTTP_PORT
    
    echo -e "${YELLOW}⏳ GitLab başlatılıyor (bu işlem 3-5 dakika sürebilir)...${NC}"
    local retries=0; local max_retries=60
    while [ $retries -lt $max_retries ]; do
        if docker logs gitlab 2>&1 | grep -q "gitlab Reconfigured!"; then
            echo -e "\n${GREEN}✅ GitLab başarıyla yapılandırıldı.${NC}"
            GITLAB_PASSWORD="$GITLAB_FIXED_ROOT_PASSWORD"
            echo -e "${GREEN}✅ GitLab root şifresi ayarlandı: ${GITLAB_PASSWORD}${NC}"
            return 0
        fi
        retries=$((retries + 1)); echo -n -e "\r${YELLOW}⏳ GitLab başlatılıyor... ($retries/$max_retries)${NC}"; sleep 5
    done
    
    echo -e "\n${RED}❌ GitLab başlatma timeout'u. Logları kontrol edin: docker logs gitlab${NC}"; return 1
}

# GitLab projesi oluştur ve manifestleri push et
create_gitlab_project_and_push_manifests() {
    echo -e "${BLUE}🤖 GitLab projesi otomatik oluşturuluyor ve manifestler push'lanıyor...${NC}"

    if [ ! -d "$MANIFESTS_PATH" ]; then
        echo -e "${RED}❌ Manifest yolu bulunamadı: $MANIFESTS_PATH${NC}"; return 1
    fi

    local GITLAB_URL="http://localhost:${GITLAB_PORT}"
    
    echo -e "${YELLOW}⏳ GitLab API'sinin hazır olması bekleniyor...${NC}"
    local retries=0; local max_retries=45
    while [ $retries -lt $max_retries ]; do
        local status_code; status_code=$(curl --silent --output /dev/null --write-out "%{http_code}" "$GITLAB_URL/-/readiness")
        if [ "$status_code" -eq 200 ]; then
            echo -e "\n${GREEN}✅ GitLab API hazır.${NC}"; break
        fi
        retries=$((retries + 1)); echo -n -e "\r${YELLOW}⏳ API bekleniyor... ($retries/$max_retries) - Durum: $status_code${NC}"; sleep 3
    done
    if [ $retries -eq $max_retries ]; then echo -e "\n${RED}❌ GitLab API'si zaman aşımına uğradı.${NC}"; return 1; fi

    # GitLab'ın 'root' kullanıcısı ID'sini al
    echo -e "${YELLOW}🆔 'root' kullanıcısının ID'si alınıyor...${NC}"
    local root_user_id
    root_user_id=$(curl --silent --request GET --header "PRIVATE-TOKEN: $GITLAB_PASSWORD" "$GITLAB_URL/api/v4/users?username=root" | jq '.[0].id')
    if [ "$root_user_id" == "null" ] || [ -z "$root_user_id" ]; then
        echo -e "${RED}❌ 'root' kullanıcısının ID'si alınamadı. API Yanıtı:${NC}"; return 1
    fi
    echo -e "${GREEN}✅ 'root' kullanıcısının ID'si: $root_user_id${NC}"

    # Impersonation Token oluşturuluyor
    echo -e "${YELLOW}🔐 Otomasyon için Impersonation Token oluşturuluyor...${NC}"
    local api_response
    api_response=$(curl --silent --request POST --header "PRIVATE-TOKEN: $GITLAB_PASSWORD" \
        --url "$GITLAB_URL/api/v4/users/$root_user_id/impersonation_tokens" \
        --data "name=argocd-automation&scopes[]=api&expires_at=$(date -d "+1 day" +%Y-%m-%d)")
    
    GITLAB_TOKEN=$(echo "$api_response" | jq -r .token)
    if [ "$GITLAB_TOKEN" == "null" ] || [ -z "$GITLAB_TOKEN" ]; then
        echo -e "${RED}❌ Impersonation Token oluşturulamadı. API Yanıtı:${NC}"; echo "$api_response"; return 1
    fi
    echo -e "${GREEN}✅ Geçici Impersonation Token başarıyla oluşturuldu.${NC}"

    echo -e "${YELLOW}🏗️  'my-app-repo' projesi oluşturuluyor...${NC}"
    project_response=$(curl --silent --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_URL/api/v4/projects" --data "name=my-app-repo&visibility=public")

    PROJECT_ID=$(echo "$project_response" | jq -r .id)
    if [ "$PROJECT_ID" == "null" ] || [ -z "$PROJECT_ID" ]; then
        echo -e "${RED}❌ GitLab projesi oluşturulamadı. API Yanıtı:${NC}"; echo "$project_response"; return 1
    fi
    echo -e "${GREEN}✅ 'my-app-repo' projesi başarıyla oluşturuldu.${NC}"

    local tmp_dir; tmp_dir=$(mktemp -d); cp -r "$MANIFESTS_PATH"/* "$tmp_dir/"
    echo -e "${YELLOW}🚀 Manifestler GitLab'a push'lanıyor...${NC}"
    ( cd "$tmp_dir"; git init -b main >/dev/null; git config user.email "s@a.com" >/dev/null; git config user.name "Automation" >/dev/null; git add . >/dev/null; git commit -m "Initial commit" >/dev/null; local REPO_URL="http://root:$GITLAB_PASSWORD@localhost:$GITLAB_PORT/root/my-app-repo.git"; git remote add origin "$REPO_URL" >/dev/null; git push -u origin main; )
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Manifestler başarıyla GitLab'a push'landı.${NC}"; rm -rf "$tmp_dir"; return 0
    else
        echo -e "${RED}❌ Manifestler GitLab'a push'lanamadı.${NC}"; rm -rf "$tmp_dir"; return 1
    fi
}

# K3D cluster oluştur
create_k3d_cluster() {
    echo -e "${BLUE}🔧 K3D cluster oluşturuluyor...${NC}"
    if k3d cluster list | grep -q "mycluster"; then
        echo -e "${YELLOW}⚠️  Mevcut 'mycluster' siliniyor...${NC}"
        k3d cluster delete mycluster
    fi
    K3D_HTTP_PORT=$(find_available_port 8080)
    K3D_HTTPS_PORT=$(find_available_port 8443)
    echo -e "${GREEN}✅ K3D portları: HTTP=$K3D_HTTP_PORT, HTTPS=$K3D_HTTPS_PORT${NC}"
    k3d cluster create mycluster --servers 1 --agents 1 -p "$K3D_HTTP_PORT:80@loadbalancer" -p "$K3D_HTTPS_PORT:443@loadbalancer"
    echo -e "${GREEN}✅ K3D cluster oluşturuldu.${NC}"
    kubectl config use-context k3d-mycluster
    echo -e "${GREEN}✅ Kubectl context k3d-mycluster olarak ayarlandı.${NC}"
}

# ArgoCD kurulumu
install_argocd() {
   echo -e "${BLUE}📦 ArgoCD kuruluyor...${NC}"
   kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --validate=false
   echo -e "${YELLOW}⏳ ArgoCD pod'larının hazır olması bekleniyor...${NC}"
   kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
   echo -e "${GREEN}✅ ArgoCD kuruldu.${NC}"
}

# ArgoCD şifresini al
get_argocd_password() {
    echo -e "${BLUE}🔐 ArgoCD admin şifresi alınıyor...${NC}"
    while ! kubectl -n argocd get secret argocd-initial-admin-secret &> /dev/null; do
        echo -n -e "\r${YELLOW}⏳ ArgoCD secret hazırlanıyor...${NC}"; sleep 5
    done
    ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    echo -e "\n${GREEN}✅ ArgoCD admin şifresi alındı.${NC}"
    echo "$ARGOCD_PASSWORD" > argocd-password.txt
    echo -e "${BLUE}💾 Şifre 'argocd-password.txt' dosyasına kaydedildi.${NC}"
}

# Boş port bul
find_available_port() {
    local port=$1
    while (echo >/dev/tcp/127.0.0.1/$port) >/dev/null 2>&1; do
        port=$((port + 1))
    done
    echo $port
}

# Port forwarding'i başlat
start_port_forward() {
    echo -e "${BLUE}🌐 Port forwarding başlatılıyor...${NC}"
    pkill -f "kubectl port-forward.*argocd-server" || true
    sleep 2
    ARGOCD_PORT=$(find_available_port 8081)
    echo -e "${GREEN}✅ ArgoCD port kullanılıyor: $ARGOCD_PORT${NC}"
    
    kubectl wait --for=condition=Ready --timeout=300s pod -l app.kubernetes.io/name=argocd-server -n argocd
    kubectl port-forward svc/argocd-server -n argocd $ARGOCD_PORT:443 > /dev/null 2>&1 &
    PORT_FORWARD_PID=$!
    
    echo -e "${YELLOW}⏳ ArgoCD server bağlantısı test ediliyor...${NC}"
    for i in {1..30}; do
        if curl -k -s --connect-timeout 2 https://localhost:$ARGOCD_PORT >/dev/null 2>&1; then
            echo -e "${GREEN}✅ ArgoCD server $ARGOCD_PORT portunda erişilebilir.${NC}"; return 0
        fi
        sleep 2
    done
    echo -e "${RED}❌ ArgoCD server bağlantısı kurulamadı.${NC}"; return 1
}

# ArgoCD'ye giriş yap ve yapılandır
login_and_configure_argocd() {
    echo -e "${BLUE}⚙️  ArgoCD'ye giriş yapılıyor ve yapılandırılıyor...${NC}"
    
    for i in {1..5}; do
        if argocd login localhost:$ARGOCD_PORT --username admin --password "$ARGOCD_PASSWORD" --insecure; then
            echo -e "${GREEN}✅ ArgoCD'ye başarıyla giriş yapıldı.${NC}"; break
        fi
        if [ $i -eq 5 ]; then echo -e "${RED}❌ ArgoCD'ye giriş yapılamadı.${NC}"; return 1; fi
        echo -e "${YELLOW}⚠️ Giriş denemesi $i/5 başarısız...${NC}"; sleep 5
    done

    local gitlab_repo_url="http://host.k3d.internal:${GITLAB_PORT}/root/my-app-repo.git"
    echo -e "${BLUE}📚 GitLab repository'si ArgoCD'ye ekleniyor... ($gitlab_repo_url)${NC}"
    for i in {1..5}; do
        if argocd repo add "$gitlab_repo_url" --username root --password "$GITLAB_PASSWORD" --insecure; then
            echo -e "${GREEN}✅ GitLab repository başarıyla eklendi.${NC}"; break
        fi
        if [ $i -eq 5 ]; then echo -e "${RED}❌ GitLab repository eklenemedi.${NC}"; return 1; fi
        echo -e "${YELLOW}⚠️ Repo ekleme denemesi $i/5 başarısız...${NC}"; sleep 3
    done

    echo -e "${BLUE}📱 ArgoCD uygulaması oluşturuluyor...${NC}"
    if argocd app create my-app --repo "$gitlab_repo_url" --path . --dest-server https://kubernetes.default.svc --dest-namespace default --sync-policy automated --self-heal --revision main; then
        echo -e "${GREEN}✅ Uygulama 'my-app' başarıyla oluşturuldu.${NC}"
    else
        echo -e "${RED}❌ Uygulama oluşturulamadı.${NC}"; argocd app get my-app; return 1
    fi
    echo -e "${BLUE}🔄 Uygulama senkronize ediliyor...${NC}"; argocd app sync my-app
    echo -e "${GREEN}✅ Uygulama sync komutu gönderildi.${NC}"; return 0
}

# Cleanup
cleanup() {
    echo -e "\n${YELLOW}🧹 Cleanup işlemi başlatılıyor...${NC}"
    if [[ -n "$PORT_FORWARD_PID" ]]; then
        kill $PORT_FORWARD_PID 2>/dev/null || true
        echo -e "${GREEN}✅ Port forwarding durduruldu.${NC}"
    fi
}
trap cleanup EXIT

# Sistem sıfırlama
reset_system() {
    echo -e "${BLUE}🧹 Sistem sıfırlanıyor...${NC}"
    pkill -f "kubectl port-forward.*argocd-server" || true
    
    echo -e "${YELLOW}🐳 GitLab Docker container durduruluyor ve siliniyor...${NC}"
    docker stop gitlab 2>/dev/null || true; docker rm gitlab 2>/dev/null || true
    echo -e "${GREEN}✅ GitLab container temizlendi.${NC}"
    
    echo -n "GitLab verilerini de (volumes) kalıcı olarak silmek istiyor musunuz? (y/N): "
    read -r confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}💾 GitLab verileri (gitlab-config, gitlab-logs, gitlab-data) siliniyor...${NC}"
        docker volume rm gitlab-config gitlab-logs gitlab-data 2>/dev/null || true
        echo -e "${GREEN}✅ GitLab verileri silindi.${NC}"
    fi
    
    if k3d cluster list | grep -q "mycluster"; then
        echo -e "${YELLOW}🗑️ K3d cluster 'mycluster' siliniyor...${NC}"
        k3d cluster delete mycluster
        echo -e "${GREEN}✅ K3D cluster 'mycluster' silindi.${NC}"
    fi
    
    echo -e "${YELLOW}📄 Geçici dosyalar siliniyor...${NC}"
    rm -f argocd-password.txt connection-info.txt
    rm -rf "$HOME/.argocd"
    echo -e "${GREEN}✅ Geçici dosyalar temizlendi.${NC}"

    echo -e "${GREEN}🎉 Sistem sıfırlama tamamlandı!${NC}"
}

# Yardım göster
show_help() {
    echo "Kullanım: $0 [setup|reset|help]"
}

# Kurulum ana fonksiyonu
setup_system() {
    echo -e "${BLUE}🚀 K3D Cluster, ArgoCD ve GitLab Setup Script${NC}\n"
    check_requirements
    create_k3d_cluster
    install_gitlab
    if [ $? -ne 0 ]; then echo -e "${RED}❌ GitLab kurulumu başarısız oldu.${NC}"; exit 1; fi
    
    create_gitlab_project_and_push_manifests
    if [ $? -ne 0 ]; then echo -e "${RED}❌ GitLab projesi oluşturma/push'lama başarısız oldu.${NC}"; exit 1; fi

    install_argocd && get_argocd_password
    
    if start_port_forward; then
        if login_and_configure_argocd; then
            echo -e "\n\n${GREEN}🎉 KURULUM TAMAMLANDI! HER ŞEY OTOMATİK OLARAK YAPILANDIRILDI.${NC}"
            echo -e "======================================================================"
            echo -e "${BLUE}📋 ÖZET:${NC}"
            echo -e "${BLUE}  • GitLab UI: http://localhost:${GITLAB_PORT} (Proje 'my-app-repo' oluşturuldu)${NC}"
            echo -e "${BLUE}  • GitLab Kullanıcı: root / Şifre: ${GITLAB_PASSWORD}${NC}"
            echo -e "${BLUE}  • ArgoCD UI: https://localhost:$ARGOCD_PORT ('my-app' uygulaması oluşturuldu)${NC}"
            echo -e "${BLUE}  • ArgoCD Kullanıcı: admin / Şifre: argocd-password.txt dosyasında${NC}"
            
            echo -e "\n${BLUE}📖 Durumu Kontrol Etmek İçin:${NC}"
            echo -e "  1. ArgoCD UI'a girip 'my-app' uygulamasının durumunu kontrol edin."
            echo -e "  2. Terminalde 'argocd app get my-app' komutunu çalıştırın."
            echo -e "  3. 'kubectl get all -n default' ile uygulamanızın kaynaklarını görün."
            
            echo -e "\n${YELLOW}💡 Port forwarding arka planda çalışıyor. Durdurmak için Ctrl+C basın...${NC}"
            wait
        else
            echo -e "\n${RED}❌ ArgoCD yapılandırması başarısız oldu.${NC}"
        fi
    else
        echo -e "\n${RED}❌ Port forwarding sorunları nedeniyle kurulum başarısız.${NC}"
    fi
}

# Ana fonksiyon
main() {
    case "${1:-setup}" in
        setup|-s|--setup)
            setup_system
            ;;
        reset|-r|--reset)
            echo -e "${RED}⚠️  Bu işlem k3d cluster, GitLab container/verileri ve tüm ArgoCD yapılandırmasını silecek!${NC}"
            echo -n "Emin misiniz? (y/N): "
            read -r confirm
            if [[ $confirm =~ ^[Yy]$ ]]; then
                reset_system
            else
                echo -e "${BLUE}ℹ️  Reset iptal edildi.${NC}"
            fi
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            echo -e "${RED}❌ Bilinmeyen seçenek: $1${NC}"; show_help; exit 1
            ;;
    esac
}

# Script'i çalıştır
main "$@"