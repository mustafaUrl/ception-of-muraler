#!/bin/bash

# K3D Cluster ve ArgoCD Setup Script
# Bu script k3d cluster oluşturur ve ArgoCD'yi kurar

set -e  # Hata durumunda scripti durdur

echo "🚀 K3D Cluster ve ArgoCD kurulumu başlatılıyor..."

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
    
    echo -e "${GREEN}✅ Tüm gereksinimler karşılandı.${NC}"
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
   kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

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

# Port forwarding başlat (arka planda)
start_port_forward() {
    echo -e "${BLUE}🌐 Port forwarding başlatılıyor...${NC}"
    
    # Mevcut port forwarding'i durdur
    pkill -f "kubectl port-forward.*argocd-server" || true
    
    # Yeni port forwarding başlat (arka planda)
    kubectl port-forward svc/argocd-server -n argocd 8081:443 &
    PORT_FORWARD_PID=$!
    
    echo -e "${GREEN}✅ Port forwarding başlatıldı (PID: $PORT_FORWARD_PID)${NC}"
    echo -e "${BLUE}🌍 ArgoCD UI: https://localhost:8081${NC}"
    
    # Port forwarding'in hazır olmasını bekle
    echo -e "${YELLOW}⏳ ArgoCD server'ın hazır olması bekleniyor...${NC}"
    sleep 10
}

# ArgoCD'ye giriş yap
login_argocd() {
    echo -e "${BLUE}🔐 ArgoCD'ye giriş yapılıyor...${NC}"
    
    # Birkaç deneme yap
    for i in {1..5}; do
        if argocd login localhost:8081 --username admin --password "$ARGOCD_PASSWORD" --insecure; then
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

# Repository ekle
add_repository() {
    echo -e "${BLUE}📚 Git repository ekleniyor...${NC}"
    
    if argocd repo add https://github.com/mustafaUrl/Inception-of-Things; then
        echo -e "${GREEN}✅ Repository başarıyla eklendi.${NC}"
    else
        echo -e "${YELLOW}⚠️  Repository zaten mevcut olabilir.${NC}"
    fi
}

# Uygulama oluştur
create_application() {
    echo -e "${BLUE}📱 ArgoCD uygulaması oluşturuluyor...${NC}"
    
    argocd app create my-app \
        --repo https://github.com/mustafaUrl/Inception-of-Things \
        --path p3/manifests \
        --dest-server https://kubernetes.default.svc \
        --dest-namespace default
    
    echo -e "${GREEN}✅ Uygulama oluşturuldu.${NC}"
}

# Uygulamayı sync et
sync_application() {
    echo -e "${BLUE}🔄 Uygulama sync ediliyor...${NC}"
    
    argocd app sync my-app
    
    echo -e "${GREEN}✅ Uygulama sync edildi.${NC}"
}

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}🧹 Starting cleanup process...${NC}"
    if [[ -n "$PORT_FORWARD_PID" ]]; then
        kill $PORT_FORWARD_PID 2>/dev/null || true
        echo -e "${GREEN}✅ Port forwarding stopped.${NC}"
    fi
}

# Run cleanup when script ends
trap cleanup EXIT

# Reset/Cleanup system
reset_system() {
    echo -e "${BLUE}🧹 Resetting system...${NC}"
    
    # Stop port forwarding
    echo -e "${YELLOW}🔌 Stopping port forwarding processes...${NC}"
    pkill -f "kubectl port-forward.*argocd-server" || true
    
    # Delete k3d cluster
    echo -e "${YELLOW}🗑️  Deleting k3d cluster 'mycluster'...${NC}"
    if k3d cluster list | grep -q "mycluster"; then
        k3d cluster delete mycluster
        echo -e "${GREEN}✅ K3D cluster 'mycluster' deleted.${NC}"
    else
        echo -e "${BLUE}ℹ️  No k3d cluster 'mycluster' found.${NC}"
    fi
    
    # Remove password file
    if [ -f "argocd-password.txt" ]; then
        rm -f argocd-password.txt
        echo -e "${GREEN}✅ Password file removed.${NC}"
    fi
    
    # Remove ArgoCD config
    ARGOCD_CONFIG_DIR="$HOME/.argocd"
    if [ -d "$ARGOCD_CONFIG_DIR" ]; then
        rm -rf "$ARGOCD_CONFIG_DIR"
        echo -e "${GREEN}✅ ArgoCD config directory removed.${NC}"
    fi
    
    echo -e "${GREEN}🎉 System reset completed!${NC}"
}

# Show help
show_help() {
    echo -e "${BLUE}🎯 K3D Cluster and ArgoCD Setup Script${NC}"
    echo -e "${BLUE}=====================================\n${NC}"
    echo -e "Usage: $0 [OPTION]"
    echo -e ""
    echo -e "Options:"
    echo -e "  setup, -s, --setup     Setup K3D cluster and ArgoCD (default)"
    echo -e "  reset, -r, --reset     Reset/cleanup the system"
    echo -e "  help, -h, --help       Show this help message"
    echo -e ""
    echo -e "Examples:"
    echo -e "  $0                     # Setup (default action)"
    echo -e "  $0 setup              # Setup K3D and ArgoCD"
    echo -e "  $0 reset              # Reset/cleanup system"
    echo -e "  $0 help               # Show help"
}

# Setup function
setup_system() {
    echo -e "${BLUE}🎯 K3D Cluster and ArgoCD Setup Script${NC}"
    echo -e "${BLUE}=====================================\n${NC}"
    
    check_requirements
    create_k3d_cluster
    install_argocd
    get_argocd_password
    
    if start_port_forward; then
        if login_argocd; then
            add_repository
            create_application
            sync_application
            
            echo -e "\n${GREEN}🎉 Setup completed!${NC}"
            echo -e "${BLUE}📋 Summary:${NC}"
            echo -e "${BLUE}  • ArgoCD UI: https://localhost:8081${NC}"
            echo -e "${BLUE}  • Username: admin${NC}"
            echo -e "${BLUE}  • Password: $ARGOCD_PASSWORD${NC}"
            echo -e "${BLUE}  • Password file: argocd-password.txt${NC}"
            echo -e "\n${YELLOW}💡 Port forwarding is running in background. Press Ctrl+C to stop.${NC}"
            
            # Wait until script ends
            echo -e "${BLUE}⏳ Script continues running. Press Ctrl+C to stop...${NC}"
            wait
        else
            echo -e "\n${YELLOW}⚠️  Setup completed but ArgoCD login failed.${NC}"
            echo -e "${BLUE}💡 You can try accessing ArgoCD manually at https://localhost:8081${NC}"
            echo -e "${BLUE}💡 Username: admin, Password: $ARGOCD_PASSWORD${NC}"
            echo -e "${BLUE}💡 Manual commands to complete setup:${NC}"
            echo -e "${BLUE}  argocd login localhost:8081 --username admin --password $ARGOCD_PASSWORD --insecure --grpc-web${NC}"
            echo -e "${BLUE}  argocd repo add https://github.com/mustafaUrl/Inception-of-Things${NC}"
            echo -e "${BLUE}  argocd app create my-app --repo https://github.com/mustafaUrl/Inception-of-Things --path p3/manifests --dest-server https://kubernetes.default.svc --dest-namespace default${NC}"
            echo -e "${BLUE}  argocd app sync my-app${NC}"
        fi
    else
        echo -e "\n${RED}❌ Setup failed due to port forwarding issues.${NC}"
        echo -e "${BLUE}💡 Try running the script again or check if port 8081 is already in use.${NC}"
    fi
}

# Main function
main() {
    case "${1:-menu}" in
        setup|-s|--setup)
            setup_system
            ;;
        reset|-r|--reset)
            echo -e "${RED}⚠️  This will delete the k3d cluster and all ArgoCD data!${NC}"
            echo -n "Are you sure? (y/N): "
            read -r confirm
            if [[ $confirm =~ ^[Yy]$ ]]; then
                reset_system
            else
                echo -e "${BLUE}ℹ️  Reset cancelled.${NC}"
            fi
            ;;
        menu|-m|--menu|"")
            interactive_menu
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            echo -e "${RED}❌ Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
    esac
}

# Run the script
main "$@"