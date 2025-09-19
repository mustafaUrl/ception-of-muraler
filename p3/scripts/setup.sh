#!/bin/bash

set -e

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

ARGOCD_PORT=""
PORT_FORWARD_PID=""
APP_PORT_FORWARD_PID=""
ARGOCD_PASSWORD=""

log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; exit 1; }

check_requirements() {
    log_info "Checking and installing required tools..."

    # Docker installation
    if ! command -v docker &> /dev/null; then
        log_warn "Docker not found. Installing..."
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl gpg
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        log_success "Docker installed."
        log_warn "Adding user '${USER}' to docker group..."
        sudo usermod -aG docker "$USER"
        log_success "User successfully added to docker group."
        log_error "Please close the terminal and reopen it for permissions to take effect, then run the script again."
    fi

    # k3d installation
    if ! command -v k3d &> /dev/null; then
        log_warn "k3d not found. Installing..."
        wget -q -O - https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
        log_success "k3d installed."
    fi

    # kubectl installation (Ubuntu 24.04 fixed)
    if ! command -v kubectl &> /dev/null; then
        log_warn "kubectl not found. Installing..."

        # Clean up any broken repo
        sudo rm -f /etc/apt/sources.list.d/kubernetes.list
        sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

        # Add new repo
        sudo apt-get update
        sudo apt-get install -y apt-transport-https ca-certificates curl gpg
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
            | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
            | sudo tee /etc/apt/sources.list.d/kubernetes.list

        sudo apt-get update
        sudo apt-get install -y kubectl
        log_success "kubectl installed."
    fi

    # Docker permission check and setup
    if ! docker info &> /dev/null; then
        if [[ $(id -Gn "$USER" | grep -c "docker") -eq 0 ]]; then
            log_warn "You don't have access to Docker daemon. Adding user '${USER}' to docker group..."
            sudo usermod -aG docker "$USER"
            log_success "User successfully added to docker group."
            log_error "Please close the terminal and reopen it for permissions to take effect, then run the script again."
        else
            log_error "Docker daemon is not running or there's another issue. Please check docker service."
        fi
    fi

    # argocd CLI installation
    if ! command -v argocd &> /dev/null; then
        log_warn "argocd CLI not found. Installing..."
        VERSION=$(curl --silent "https://api.github.com/repos/argoproj/argo-cd/releases/latest" \
            | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
        sudo curl -sSL -o /usr/local/bin/argocd \
            https://github.com/argoproj/argo-cd/releases/download/$VERSION/argocd-linux-amd64
        sudo chmod +x /usr/local/bin/argocd
        log_success "argocd CLI installed."
    fi

    log_success "All requirements satisfied."
}

create_k3d_cluster() {
    log_info "Creating K3D cluster..."
    if k3d cluster list | grep -q "mycluster"; then
        log_warn "mycluster already exists. Deleting..."
        k3d cluster delete mycluster
    fi
    k3d cluster create mycluster --servers 1 --agents 1 \
        -p "8080:80@loadbalancer" -p "8443:443@loadbalancer"
    log_success "K3D cluster created."
}

install_argocd() {
    log_info "Installing ArgoCD..."
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
    log_success "ArgoCD installed."
}

create_dev_namespace() {
    log_info "Creating 'dev' namespace..."
    kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -
    log_success "'dev' namespace created."
}

get_argocd_password() {
    log_info "Getting ArgoCD admin password..."
    until kubectl -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; do sleep 5; done
    ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    log_success "Admin password retrieved successfully."
}

find_available_port() {
    local start=${1:-8081}
    for port in $(seq $start $((start+50))); do
        ! lsof -i :$port >/dev/null 2>&1 && echo $port && return 0
    done
    log_error "No available port found between 8081-8131."
}

start_port_forward() {
    ARGOCD_PORT=$(find_available_port 8081)
    log_info "Starting port forwarding... Port: $ARGOCD_PORT"
    kubectl wait --for=condition=Ready --timeout=300s pod -l app.kubernetes.io/name=argocd-server -n argocd
    kubectl port-forward svc/argocd-server -n argocd $ARGOCD_PORT:443 >/dev/null 2>&1 &
    PORT_FORWARD_PID=$!
    sleep 3
    if ! kill -0 $PORT_FORWARD_PID >/dev/null 2>&1; then
        log_error "Could not start port forwarding."
    fi
    log_success "Port forwarding started: https://localhost:$ARGOCD_PORT"
}

login_argocd() {
    log_info "Logging into ArgoCD..."
    if ! argocd login localhost:$ARGOCD_PORT --username admin --password "$ARGOCD_PASSWORD" --insecure; then
        log_error "ArgoCD login failed!"
    fi
    log_success "ArgoCD login successful."
}

add_repository() {
    log_info "Adding GitHub repository..."
    if ! argocd repo add https://github.com/mustafaUrl/ception-of-muraler; then
        log_warn "Repository might already be added."
    else
        log_success "Repository added."
    fi
}

create_application() {
    log_info "Creating ArgoCD application..."
    if ! argocd app create my-app \
        --repo https://github.com/mustafaUrl/ception-of-muraler \
        --path p3/manifests \
        --dest-server https://kubernetes.default.svc \
        --dest-namespace dev \
        --sync-policy automated; then
        log_warn "Application might already exist."
    else
        log_success "Application created."
    fi
}

sync_application() {
    log_info "Syncing application..."
    argocd app sync my-app
    log_success "Application synced."
}

# Application port forwarding fonksiyonları
start_app_port_forward() {
    log_info "Starting port-forward for application (8888 -> 80)..."
    
    # Clear old port forwards
    pkill -f "kubectl port-forward.*my-app-service" 2>/dev/null || true
    
    # Wait for the deployment to be ready
    kubectl wait --for=condition=available --timeout=300s deployment/my-app-deployment -n dev
    
    # Start port forwarding
    kubectl port-forward svc/my-app-service -n dev 8888:80 >/dev/null 2>&1 &
    APP_PORT_FORWARD_PID=$!
    
    sleep 3
    
    if kill -0 $APP_PORT_FORWARD_PID >/dev/null 2>&1; then
        log_success "Application port forwarding started: http://localhost:8888"
    else
        log_error "Could not start application port forwarding."
    fi
}

monitor_pod_changes() {
    log_info "Starting pod change monitor..."
    local last_pod_name=""
    
    while true; do
        # Take the current pod name
        current_pod=$(kubectl get pods -n dev -l app=my-app --no-headers 2>/dev/null | awk '{print $1}' | head -1)
        
        if [[ -n "$current_pod" && "$current_pod" != "$last_pod_name" ]]; then
            if [[ -n "$last_pod_name" ]]; then
                log_warn "Pod changed from '$last_pod_name' to '$current_pod'. Restarting port forwarding..."
                
                # Kill the old port forwarding
                if [[ -n "$APP_PORT_FORWARD_PID" ]]; then
                    kill $APP_PORT_FORWARD_PID 2>/dev/null || true
                fi
                pkill -f "kubectl port-forward.*my-app-service" 2>/dev/null || true
                
                # Wait for the new pod to be ready
                kubectl wait --for=condition=Ready --timeout=60s pod/$current_pod -n dev 2>/dev/null || true
                
                # Restart port forwarding
                start_app_port_forward
            fi
            last_pod_name="$current_pod"
        fi
        
        sleep 5
    done
}

restart_port_forward() {
    log_info "Restarting application port forwarding..."
    pkill -f "kubectl port-forward.*my-app-service" 2>/dev/null || true
    sleep 2
    start_app_port_forward
}

cleanup() {
    [[ -n "$PORT_FORWARD_PID" ]] && kill $PORT_FORWARD_PID 2>/dev/null
    [[ -n "$APP_PORT_FORWARD_PID" ]] && kill $APP_PORT_FORWARD_PID 2>/dev/null
    pkill -f "kubectl port-forward.*my-app-service" 2>/dev/null || true
}

trap cleanup EXIT

reset_system() {
    pkill -f "kubectl port-forward.*argocd-server" || true
    pkill -f "kubectl port-forward.*my-app-service" || true
    k3d cluster delete mycluster || true
    rm -rf "$HOME/.argocd"
    log_success "System reset."
}

setup_system() {
    check_requirements
    create_k3d_cluster
    install_argocd

    log_info "Removing ArgoCD resource.exclusions and restarting server..."
    kubectl patch configmap argocd-cm -n argocd --type='json' -p='[{"op": "remove", "path": "/data/resource.exclusions"}]' 2>/dev/null || echo -e "${YELLOW}ℹ️  resource.exclusions not present${NC}"
    kubectl rollout restart deployment argocd-server -n argocd
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
    log_success "ArgoCD server restarted."

    create_dev_namespace
    get_argocd_password
    start_port_forward
    login_argocd
    add_repository
    create_application
    sync_application

    log_info "Waiting for my-app-deployment to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/my-app-deployment -n dev
    log_success "my-app-deployment ready."

    # Start the first port forwarding
    start_app_port_forward
    
    log_success "Setup completed! ArgoCD UI: https://localhost:$ARGOCD_PORT"
    log_success "Your application is now accessible at http://localhost:8888."
    log_warn "Your initial admin password: $ARGOCD_PASSWORD"
    log_warn "For security, please change your password on first login."
    
    # Start monitoring pod changes
    log_info "Monitoring pod changes for automatic port forwarding restart..."
    monitor_pod_changes &
    
    wait
}

main() {
    case "${1:-setup}" in
        setup|-s|--setup) setup_system ;;
        reset|-r|--reset) reset_system ;;
        restart-port|-rp|--restart-port) restart_port_forward ;;
        help|-h|--help) 
            echo "Usage: $0 [setup|reset|restart-port|help]"
            echo "  setup: Full system setup"
            echo "  reset: Reset the entire system"
            echo "  restart-port: Restart application port forwarding"
            ;;
        *) log_error "Unknown option: $1" ;;
    esac
}

main "$@"