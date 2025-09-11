#!/bin/bash

# K3D Cluster, ArgoCD ve GitLab Setup Script
# Bu script k3d cluster oluşturur, ArgoCD'yi kurar ve GitLab'ı yapılandırır

ARGOCD_PORT=""
GITLAB_PORT=""
PORT_FORWARD_PID=""
GITLAB_PID=""
set -e  # Hata durumunda scripti durdur

echo "🚀 K3D Cluster, ArgoCD ve GitLab kurulumu başlatılıyor..."

# Renkli output için
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Gerekli araçları kontrol et
check_requirements() {
    echo -e "${BLUE}📋 Gerekli araçlar kontrol ediliyor...${NC}"
    
    if ! command -v k3d &> /dev/null; then
        echo -e "${RED}❌ k3d bulunamadı. Lütfen k3d'yi kurun.${NC}"
        exit 1
    fi
    
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}❌ kubectl bulunamadı. Lütfen kubectl'i kurun.${NC}"
        exit 1
    fi
    
    if ! command -v argocd &> /dev/null; then
        echo -e "${YELLOW}⚠️  argocd CLI bulunamadı. ArgoCD CLI kurulacak...${NC}"
        exit 1
    fi
    
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}❌ Docker bulunamadı. Lütfen Docker'ı kurun.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✅ Tüm gereksinimler karşılandı.${NC}"
}

# GitLab kurulumu
install_gitlab() {
    echo -e "${BLUE}🦊 GitLab Community Edition kuruluyor...${NC}"
    
    # GitLab namespace oluştur
    kubectl create namespace gitlab --dry-run=client -o yaml | kubectl apply -f -
    
    # GitLab Helm repository ekle (eğer Helm varsa)
    if command -v helm &> /dev/null; then
        echo -e "${BLUE}🎯 GitLab Helm chart ile kuruluyor...${NC}"
        helm repo add gitlab https://charts.gitlab.io/
        helm repo update
        
        # GitLab'ı basit yapılandırma ile kur
        helm upgrade --install gitlab gitlab/gitlab \
            --namespace gitlab \
            --set global.hosts.domain=localhost \
            --set global.hosts.externalIP=127.0.0.1 \
            --set certmanager.install=false \
            --set nginx-ingress.enabled=false \
            --set prometheus.install=false \
            --set gitlab-runner.install=false \
            --set registry.enabled=false \
            --set global.ingress.enabled=false \
            --timeout 600s
    else
        echo -e "${BLUE}🐳 GitLab Docker container ile kuruluyor...${NC}"
        # Docker ile GitLab çalıştır
        docker run -d \
            --name gitlab \
            --hostname gitlab.localhost \
            -p 8080:80 \
            -p 8443:443 \
            -p 8022:22 \
            --volume gitlab-config:/etc/gitlab \
            --volume gitlab-logs:/var/log/gitlab \
            --volume gitlab-data:/var/opt/gitlab \
            --restart unless-stopped \
            gitlab/gitlab-ce:latest
        
        echo -e "${YELLOW}⏳ GitLab başlatılıyor (bu işlem 2-3 dakika sürebilir)...${NC}"
        
        # GitLab'ın hazır olmasını bekle
        local retries=0
        local max_retries=60
        
        while [ $retries -lt $max_retries ]; do
            if docker logs gitlab 2>&1 | grep -q "gitlab Reconfigured!"; then
                echo -e "${GREEN}✅ GitLab başarıyla başlatıldı.${NC}"
                break
            fi
            
            retries=$((retries + 1))
            echo -e "${YELLOW}⏳ GitLab başlatılıyor... ($retries/$max_retries)${NC}"
            sleep 5
        done
        
        if [ $retries -eq $max_retries ]; then
            echo -e "${RED}❌ GitLab başlatma timeout'u. Logları kontrol edin: docker logs gitlab${NC}"
            return 1
        fi
    fi
    
    echo -e "${GREEN}✅ GitLab kuruldu.${NC}"
}

# GitLab root şifresini al
get_gitlab_password() {
    echo -e "${BLUE}🔐 GitLab root şifresi alınıyor...${NC}"
    
    if docker ps | grep -q gitlab; then
        # Docker container'dan şifreyi al
        local retries=0
        local max_retries=30
        
        while [ $retries -lt $max_retries ]; do
            GITLAB_PASSWORD=$(docker exec gitlab grep 'Password:' /etc/gitlab/initial_root_password 2>/dev/null | awk '{print $2}' || echo "")
            
            if [ -n "$GITLAB_PASSWORD" ]; then
                echo -e "${GREEN}✅ GitLab root şifresi: ${GITLAB_PASSWORD}${NC}"
                echo "$GITLAB_PASSWORD" > gitlab-password.txt
                echo -e "${BLUE}💾 Şifre 'gitlab-password.txt' dosyasına kaydedildi.${NC}"
                return 0
            fi
            
            retries=$((retries + 1))
            echo -e "${YELLOW}⏳ Şifre dosyası oluşturuluyor... ($retries/$max_retries)${NC}"
            sleep 5
        done
        
        echo -e "${YELLOW}⚠️  Otomatik şifre alınamadı. GitLab UI'dan şifreyi manuel olarak değiştirebilirsiniz.${NC}"
        GITLAB_PASSWORD="manuel_olarak_değiştirin"
    else
        # Kubernetes deployment için
        echo -e "${YELLOW}⚠️  Helm kurulumu için GitLab şifresi kubectl ile alınmalı.${NC}"
        GITLAB_PASSWORD="kubectl_ile_alin"
    fi
}

# K3D cluster oluştur
create_k3d_cluster() {
    echo -e "${BLUE}🔧 K3D cluster oluşturuluyor...${NC}"
    
    # Mevcut cluster'ı sil (varsa)
    if k3d cluster list | grep -q "mycluster"; then
        echo -e "${YELLOW}⚠️  Mevcut 'mycluster' siliniyor...${NC}"
        k3d cluster delete mycluster
    fi
    
    # Yeni cluster oluştur
    k3d cluster create mycluster \
        --servers 1 \
        --agents 1 \
        -p "8080:80@loadbalancer" \
        -p "8443:443@loadbalancer"
    
    echo -e "${GREEN}✅ K3D cluster oluşturuldu.${NC}"
}

# ArgoCD kurulumu
install_argocd() {
   echo -e "${BLUE}📦 ArgoCD kuruluyor...${NC}"
   
   # ArgoCD namespace oluştur
   kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
   
   # ArgoCD manifest'lerini uygula
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   
   echo -e "${YELLOW}⏳ ArgoCD pod'larının hazır olması bekleniyor...${NC}"
   kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

   # Endpoints ve EndpointSlices'ları görünür yap
   echo -e "${BLUE}🔧 Endpoints ve EndpointSlices görünür yapılıyor...${NC}"
   kubectl patch configmap argocd-cm -n argocd --type='json' -p='[{"op": "remove", "path": "/data/resource.exclusions"}]' 2>/dev/null || echo -e "${YELLOW}ℹ️  resource.exclusions zaten mevcut değil${NC}"
   kubectl rollout restart deployment argocd-server -n argocd
   kubectl wait --for=condition=available --timeout=300s deployment argocd-server -n argocd

   echo -e "${GREEN}✅ ArgoCD kuruldu ve yapılandırıldı.${NC}"
}

# ArgoCD şifresini al
get_argocd_password() {
    echo -e "${BLUE}🔐 ArgoCD admin şifresi alınıyor...${NC}"
    
    # Şifrenin hazır olmasını bekle
    while ! kubectl -n argocd get secret argocd-initial-admin-secret &> /dev/null; do
        echo -e "${YELLOW}⏳ ArgoCD secret hazırlanıyor...${NC}"
        sleep 5
    done
    
    ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    echo -e "${GREEN}✅ ArgoCD admin şifresi: ${ARGOCD_PASSWORD}${NC}"
    
    # Şifreyi dosyaya kaydet
    echo "$ARGOCD_PASSWORD" > argocd-password.txt
    echo -e "${BLUE}💾 Şifre 'argocd-password.txt' dosyasına kaydedildi.${NC}"
}

# Find available port
find_available_port() {
    local start_port=${1:-8081}
    local max_port=$((start_port + 50))
    
    for port in $(seq $start_port $max_port); do
        if ! lsof -i :$port >/dev/null 2>&1 && ! netstat -an | grep -q ":$port "; then
            echo $port
            return 0
        fi
    done
    
    echo -e "${RED}❌ $start_port ve $max_port arasında kullanılabilir port bulunamadı${NC}" >&2
    return 1
}

start_port_forward() {
    echo -e "${BLUE}🌐 Port forwarding başlatılıyor...${NC}"
    
    # Mevcut port forwarding'i durdur
    pkill -f "kubectl port-forward.*argocd-server" || true
    sleep 2
    
    # Kullanılabilir port bul
    echo -e "${YELLOW}🔍 Kullanılabilir port aranıyor...${NC}"
    ARGOCD_PORT=$(find_available_port 8081)
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ ArgoCD için kullanılabilir port bulunamadı${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Port kullanılıyor: $ARGOCD_PORT${NC}"
    
    # ArgoCD server pod'unun hazır olmasını bekle
    echo -e "${YELLOW}⏳ ArgoCD server pod'unun hazır olması bekleniyor...${NC}"
    kubectl wait --for=condition=Ready --timeout=300s pod -l app.kubernetes.io/name=argocd-server -n argocd
    
    # Yeni port forwarding başlat (arka planda)
    kubectl port-forward svc/argocd-server -n argocd $ARGOCD_PORT:443 > /dev/null 2>&1 &
    PORT_FORWARD_PID=$!
    
    echo -e "${GREEN}✅ Port forwarding başlatıldı (PID: $PORT_FORWARD_PID)${NC}"
    echo -e "${BLUE}🌍 ArgoCD UI: https://localhost:$ARGOCD_PORT${NC}"
    
    # Bağlantıyı test et
    echo -e "${YELLOW}⏳ ArgoCD server bağlantısı test ediliyor...${NC}"
    local retries=0
    local max_retries=30
    
    while [ $retries -lt $max_retries ]; do
        if curl -k -s --connect-timeout 2 https://localhost:$ARGOCD_PORT >/dev/null 2>&1; then
            echo -e "${GREEN}✅ ArgoCD server $ARGOCD_PORT portunda erişilebilir.${NC}"
            return 0
        fi
        
        # Port forward process'inin çalışıp çalışmadığını kontrol et
        if ! kill -0 $PORT_FORWARD_PID 2>/dev/null; then
            echo -e "${RED}❌ Port forwarding process durdu. Yeniden başlatılıyor...${NC}"
            kubectl port-forward svc/argocd-server -n argocd $ARGOCD_PORT:443 > /dev/null 2>&1 &
            PORT_FORWARD_PID=$!
        fi
        
        retries=$((retries + 1))
        echo -e "${YELLOW}⏳ Deneme $retries/$max_retries - ArgoCD server $ARGOCD_PORT portunda bekleniyor...${NC}"
        sleep 2
    done
    
    echo -e "${RED}❌ ArgoCD server $ARGOCD_PORT portunda kararlı bağlantı kurulamadı.${NC}"
    return 1
}

# ArgoCD'ye giriş yap
login_argocd() {
    echo -e "${BLUE}🔐 ArgoCD'ye giriş yapılıyor...${NC}"
    
    # Birkaç deneme yap
    for i in {1..5}; do
        if argocd login localhost:$ARGOCD_PORT --username admin --password "$ARGOCD_PASSWORD" --insecure; then
            echo -e "${GREEN}✅ ArgoCD'ye başarıyla giriş yapıldı.${NC}"
            return 0
        else
            echo -e "${YELLOW}⚠️  Giriş denemesi $i/5 başarısız. Tekrar deneniyor...${NC}"
            sleep 5
        fi
    done
    
    echo -e "${RED}❌ ArgoCD'ye giriş yapılamadı.${NC}"
    return 1
}

# GitLab repository ekle
add_gitlab_repository() {
    echo -e "${BLUE}📚 GitLab repository ArgoCD'ye ekleniyor...${NC}"
    
    # GitLab repository URL'i (yerel GitLab instance)
    local gitlab_repo_url="http://localhost:8080/root/my-app-repo.git"
    
    echo -e "${YELLOW}💡 GitLab repository manuel olarak oluşturulmalı:${NC}"
    echo -e "${BLUE}  1. GitLab UI'da (http://localhost:8080) 'root' kullanıcısı ile giriş yapın${NC}"
    echo -e "${BLUE}  2. 'my-app-repo' adında yeni bir proje oluşturun${NC}"
    echo -e "${BLUE}  3. Manifest dosyalarınızı bu repository'ye yükleyin${NC}"
    
    # Repository'yi ArgoCD'ye ekle (GitLab hazır olduktan sonra)
    if argocd repo add $gitlab_repo_url --username root --password "$GITLAB_PASSWORD" 2>/dev/null; then
        echo -e "${GREEN}✅ GitLab repository başarıyla eklendi.${NC}"
    else
        echo -e "${YELLOW}⚠️  Repository henüz mevcut değil veya credentials hatalı.${NC}"
        echo -e "${BLUE}💡 GitLab repository hazır olduktan sonra manuel olarak ekleyin:${NC}"
        echo -e "${BLUE}  argocd repo add $gitlab_repo_url --username root --password [gitlab-password]${NC}"
    fi
}

# Uygulama oluştur (GitLab ile)
create_application_gitlab() {
    echo -e "${BLUE}📱 ArgoCD uygulaması GitLab ile oluşturuluyor...${NC}"
    
    local gitlab_repo_url="http://localhost:8080/root/my-app-repo.git"
    
    if argocd app create my-app \
        --repo $gitlab_repo_url \
        --path manifests \
        --dest-server https://kubernetes.default.svc \
        --dest-namespace default \
        --revision HEAD 2>/dev/null; then
        echo -e "${GREEN}✅ Uygulama GitLab repository ile oluşturuldu.${NC}"
    else
        echo -e "${YELLOW}⚠️  Uygulama oluşturulamadı. GitLab repository henüz hazır olmayabilir.${NC}"
        echo -e "${BLUE}💡 GitLab repository hazır olduktan sonra manuel olarak oluşturun:${NC}"
        echo -e "${BLUE}  argocd app create my-app --repo $gitlab_repo_url --path manifests --dest-server https://kubernetes.default.svc --dest-namespace default${NC}"
    fi
}

# Uygulama sync et
sync_application() {
    echo -e "${BLUE}🔄 Uygulama sync ediliyor...${NC}"
    
    if argocd app sync my-app 2>/dev/null; then
        echo -e "${GREEN}✅ Uygulama sync edildi.${NC}"
    else
        echo -e "${YELLOW}⚠️  Uygulama sync edilemedi. Uygulama henüz mevcut olmayabilir.${NC}"
    fi
}

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}🧹 Cleanup işlemi başlatılıyor...${NC}"
    if [[ -n "$PORT_FORWARD_PID" ]]; then
        kill $PORT_FORWARD_PID 2>/dev/null || true
        echo -e "${GREEN}✅ Port forwarding durduruldu.${NC}"
    fi
    
    if [[ -n "$GITLAB_PID" ]]; then
        kill $GITLAB_PID 2>/dev/null || true
        echo -e "${GREEN}✅ GitLab process durduruldu.${NC}"
    fi
}

# Cleanup'ı script bittiğinde çalıştır
trap cleanup EXIT

# System reset/cleanup
reset_system() {
    echo -e "${BLUE}🧹 Sistem sıfırlanıyor...${NC}"
    
    # Port forwarding'i durdur
    echo -e "${YELLOW}🔌 Port forwarding işlemleri durduruluyor...${NC}"
    pkill -f "kubectl port-forward.*argocd-server" || true
    
    # GitLab Docker container'ını durdur ve sil
    echo -e "${YELLOW}🐳 GitLab Docker container durduruluyor...${NC}"
    docker stop gitlab 2>/dev/null || true
    docker rm gitlab 2>/dev/null || true
    
    # GitLab volumes'ları sil (opsiyonel)
    echo -n "GitLab verilerini de silmek istiyor musunuz? (y/N): "
    read -r confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        docker volume rm gitlab-config gitlab-logs gitlab-data 2>/dev/null || true
        echo -e "${GREEN}✅ GitLab verileri silindi.${NC}"
    fi
    
    # K3d cluster'ı sil
    echo -e "${YELLOW}🗑️  K3d cluster 'mycluster' siliniyor...${NC}"
    if k3d cluster list | grep -q "mycluster"; then
        k3d cluster delete mycluster
        echo -e "${GREEN}✅ K3D cluster 'mycluster' silindi.${NC}"
    else
        echo -e "${BLUE}ℹ️  K3d cluster 'mycluster' bulunamadı.${NC}"
    fi
    
    # Şifre dosyalarını sil
    rm -f argocd-password.txt gitlab-password.txt argocd-connection.txt gitlab-connection.txt
    echo -e "${GREEN}✅ Şifre dosyaları silindi.${NC}"
    
    # ArgoCD config'ini sil
    ARGOCD_CONFIG_DIR="$HOME/.argocd"
    if [ -d "$ARGOCD_CONFIG_DIR" ]; then
        rm -rf "$ARGOCD_CONFIG_DIR"
        echo -e "${GREEN}✅ ArgoCD config dizini silindi.${NC}"
    fi
    
    echo -e "${GREEN}🎉 Sistem sıfırlama tamamlandı!${NC}"
}

# Yardım göster
show_help() {
    echo -e "${BLUE}🎯 K3D Cluster, ArgoCD ve GitLab Setup Script${NC}"
    echo -e "${BLUE}=============================================\n${NC}"
    echo -e "Kullanım: $0 [SEÇENEK]"
    echo -e ""
    echo -e "Seçenekler:"
    echo -e "  setup, -s, --setup     K3D cluster, ArgoCD ve GitLab kur (varsayılan)"
    echo -e "  reset, -r, --reset     Sistem sıfırla/temizle"
    echo -e "  help, -h, --help       Bu yardım mesajını göster"
    echo -e ""
    echo -e "Örnekler:"
    echo -e "  $0                     # Setup (varsayılan işlem)"
    echo -e "  $0 setup              # K3D, ArgoCD ve GitLab kur"
    echo -e "  $0 reset              # Sistem sıfırla/temizle"
    echo -e "  $0 help               # Yardım göster"
    echo -e ""
    echo -e "${BLUE}🦊 GitLab Bilgileri:${NC}"
    echo -e "  • GitLab Docker container ile kurulacak"
    echo -e "  • Yerel erişim: http://localhost:8080"
    echo -e "  • SSH erişim: localhost:8022"
    echo -e "  • Varsayılan kullanıcı: root"
}

# Setup function
setup_system() {
    echo -e "${BLUE}🎯 K3D Cluster, ArgoCD ve GitLab Setup Script${NC}"
    echo -e "${BLUE}=============================================\n${NC}"
    
    check_requirements
    
    # GitLab'ı önce kur (en uzun süren işlem)
    install_gitlab
    get_gitlab_password
    
    # K3D ve ArgoCD'yi kur
    create_k3d_cluster
    install_argocd
    get_argocd_password
    
    if start_port_forward; then
        if login_argocd; then
            add_gitlab_repository
            create_application_gitlab
            sync_application
            
            echo -e "\n${GREEN}🎉 Kurulum tamamlandı!${NC}"
            echo -e "${BLUE}📋 Özet:${NC}"
            echo -e "${BLUE}  • GitLab UI: http://localhost:8080${NC}"
            echo -e "${BLUE}  • GitLab Kullanıcı: root${NC}"
            echo -e "${BLUE}  • GitLab Şifre: $GITLAB_PASSWORD${NC}"
            echo -e "${BLUE}  • ArgoCD UI: https://localhost:$ARGOCD_PORT${NC}"
            echo -e "${BLUE}  • ArgoCD Kullanıcı: admin${NC}"
            echo -e "${BLUE}  • ArgoCD Şifre: $ARGOCD_PASSWORD${NC}"
            echo -e "${BLUE}  • ArgoCD Şifre dosyası: argocd-password.txt${NC}"
            echo -e "${BLUE}  • GitLab Şifre dosyası: gitlab-password.txt${NC}"
            echo -e "${BLUE}  • Kullanılan port: $ARGOCD_PORT${NC}"
            echo -e "\n${YELLOW}💡 Port forwarding arka planda çalışıyor. Durdurmak için Ctrl+C basın.${NC}"
            echo -e "\n${BLUE}📖 Sonraki Adımlar:${NC}"
            echo -e "${BLUE}  1. GitLab'a giriş yapın: http://localhost:8080 (root / $GITLAB_PASSWORD)${NC}"
            echo -e "${BLUE}  2. 'my-app-repo' adında yeni proje oluşturun${NC}"
            echo -e "${BLUE}  3. Kubernetes manifest dosyalarınızı 'manifests' klasörüne yükleyin${NC}"
            echo -e "${BLUE}  4. ArgoCD'de repository ve uygulamayı manuel olarak yapılandırın${NC}"
            
            # Bağlantı bilgilerini dosyaya kaydet
            cat > connection-info.txt << EOF
# GitLab Bağlantı Bilgileri
GITLAB_URL=http://localhost:8080
GITLAB_SSH=localhost:8022
GITLAB_USERNAME=root
GITLAB_PASSWORD=$GITLAB_PASSWORD

# ArgoCD Bağlantı Bilgileri
ARGOCD_URL=https://localhost:$ARGOCD_PORT
ARGOCD_USERNAME=admin
ARGOCD_PASSWORD=$ARGOCD_PASSWORD

# Repository URL (GitLab'da proje oluşturduktan sonra)
GITLAB_REPO_URL=http://localhost:8080/root/my-app-repo.git
EOF
            echo -e "${BLUE}💾 Tüm bağlantı bilgileri 'connection-info.txt' dosyasına kaydedildi.${NC}"
            
            # Script çalışmaya devam etsin
            echo -e "${BLUE}⏳ Script çalışmaya devam ediyor. Durdurmak için Ctrl+C basın...${NC}"
            wait
        else
            echo -e "\n${YELLOW}⚠️  Kurulum tamamlandı ancak ArgoCD girişi başarısız.${NC}"
            echo -e "${BLUE}💡 ArgoCD'ye manuel olarak erişebilirsiniz: https://localhost:$ARGOCD_PORT${NC}"
            echo -e "${BLUE}💡 Kullanıcı: admin, Şifre: $ARGOCD_PASSWORD${NC}"
        fi
    else
        echo -e "\n${RED}❌ Port forwarding sorunları nedeniyle kurulum başarısız.${NC}"
        echo -e "${BLUE}💡 Script'i tekrar çalıştırmayı deneyin veya portların kullanılabilir olduğunu kontrol edin.${NC}"
    fi
}

# Interactive menu
interactive_menu() {
    echo -e "${BLUE}🎯 K3D Cluster, ArgoCD ve GitLab Setup Script${NC}"
    echo -e "${BLUE}=============================================\n${NC}"
    echo -e "Seçenekler:"
    echo -e "  1) 🚀 Setup (K3D + ArgoCD + GitLab kur)"
    echo -e "  2) 🧹 Reset (Sistemi temizle)"
    echo -e "  3) ❓ Help (Yardım)"
    echo -e "  4) 🚪 Exit (Çıkış)"
    echo -e ""
    echo -n "Seçiminizi yapın (1-4): "
    read -r choice
    
    case $choice in
        1)
            setup_system
            ;;
        2)
            echo -e "${RED}⚠️  Bu işlem k3d cluster, GitLab ve tüm ArgoCD verilerini silecek!${NC}"
            echo -n "Emin misiniz? (y/N): "
            read -r confirm
            if [[ $confirm =~ ^[Yy]$ ]]; then
                reset_system
            else
                echo -e "${BLUE}ℹ️  Reset iptal edildi.${NC}"
            fi
            ;;
        3)
            show_help
            ;;
        4)
            echo -e "${BLUE}👋 Çıkılıyor...${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ Geçersiz seçim: $choice${NC}"
            interactive_menu
            ;;
    esac
}

# Main function
main() {
    case "${1:-menu}" in
        setup|-s|--setup)
            setup_system
            ;;
        reset|-r|--reset)
            echo -e "${RED}⚠️  Bu işlem k3d cluster, GitLab ve tüm ArgoCD verilerini silecek!${NC}"
            echo -n "Emin misiniz? (y/N): "
            read -r confirm
            if [[ $confirm =~ ^[Yy]$ ]]; then
                reset_system
            else
                echo -e "${BLUE}ℹ️  Reset iptal edildi.${NC}"
            fi
            ;;
        menu|-m|--menu|"")
            interactive_menu
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            echo -e "${RED}❌ Bilinmeyen seçenek: $1${NC}"
            show_help
            exit 1
            ;;
    esac
}

# Script'i çalıştır
main "$@"