#!/bin/bash

# Define variables
K3D_CLUSTER_NAME="my-argocd-cluster"
ARGO_CD_NAMESPACE="argocd"
APP_NAME="will-playground-app"
REPO_URL="https://github.com/mustafaUrl/Inception-of-Things.git"
PATH_IN_REPO="p3/manifests/will-playground"
DEST_SERVER="https://kubernetes.default.svc"
DEST_NAMESPACE="will-playground"
SYNC_POLICY="Automatic"

# --- Utility Functions ---

# Function to clean up the cluster and associated processes
cleanup_cluster() {
    echo "Cleaning up k3d cluster: ${K3D_CLUSTER_NAME}..."
    k3d cluster delete "${K3D_CLUSTER_NAME}" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "Warning: k3d cluster deletion might have failed or cluster did not exist. Continuing..."
    fi
    cleanup_argocd_processes # Call the Argo CD specific cleanup
}

# Function to clean up Argo CD specific resources and processes
cleanup_argocd_processes() {
    echo "Attempting to delete Argo CD namespace: ${ARGO_CD_NAMESPACE}..."
    kubectl delete namespace "${ARGO_CD_NAMESPACE}" --ignore-not-found --timeout=60s > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "Warning: Argo CD namespace deletion might have failed or timed out. Manual check recommended."
    fi
    echo "Killing any lingering kubectl port-forward processes for Argo CD UI..."
    # Kill any process that looks like "kubectl port-forward svc/argocd-server -n argocd"
    pkill -f "kubectl port-forward svc/argocd-server -n ${ARGO_CD_NAMESPACE}" > /dev/null 2>&1
    sleep 2 # Give some time for processes to terminate
}

# Function to check if a port is in use
is_port_in_use() {
    local port=$1
    if command -v lsof &> /dev/null; then
        # Linux/macOS
        lsof -i :${port} > /dev/null 2>&1
        return $? # Returns 0 if port is in use, 1 otherwise
    elif command -v netstat &> /dev/null; then
        # Windows (via WSL or similar, or native if executed in cmd/powershell)
        netstat -ano | findstr ":${port}" | findstr "LISTENING" > /dev/null 2>&1
        return $?
    else
        echo "Warning: 'lsof' or 'netstat' not found. Cannot reliably check port status."
        return 1 # Assume not in use if check is not possible
    fi
}

# Function to find an available port
find_available_port() {
    local start_port=$1
    local end_port=$2
    for ((p=start_port; p<=end_port; p++)); do
        if ! is_port_in_use "${p}"; then
            echo "${p}"
            return 0
        fi
    done
    return 1 # No available port found in range
}

# Function to perform port-forwarding with retry logic and dynamic port finding
start_port_forward() {
    local service_name=$1
    local namespace=$2
    local remote_port=$3
    local pid_var_name=$4 # Name of the variable to store PID

    local found_port=""
    local retries=5 # Number of times to try finding a new port

    echo "Attempting to find an available local port for port-forwarding..."
    for i in $(seq 1 $retries); do
        found_port=$(find_available_port 8080 8090) # Try ports from 8080 to 8090
        if [ -n "$found_port" ]; then
            echo "Found available port: ${found_port}"
            break
        else
            echo "No available port found in range 8080-8090 (Attempt ${i}/${retries}). Retrying..."
            sleep 2
        fi
    done

    if [ -z "$found_port" ]; then
        echo "Error: Could not find an available local port for port-forwarding."
        return 1
    fi

    # Ensure previous temporary port-forwards are killed before starting a new one
    pkill -f "kubectl port-forward svc/${service_name} -n ${namespace}" > /dev/null 2>&1
    sleep 1

    echo "Starting port-forward for ${service_name} on local port ${found_port}..."
    kubectl port-forward svc/"${service_name}" -n "${namespace}" "${found_port}":"${remote_port}" > /dev/null 2>&1 &
    local pid=$!
    sleep 3 # Give some time for the port-forward to establish or fail

    # Check if the process is still running and listening on the port
    if ps -p ${pid} > /dev/null && is_port_in_use "${found_port}"; then
        echo "Port-forward started successfully with PID: ${pid} on port ${found_port}."
        eval "${pid_var_name}=${pid}" # Assign PID to the given variable name
        eval "ARGO_CD_UI_PORT_USED=${found_port}" # Store the used port in a global variable
        return 0 # Success
    else
        echo "Error: Port-forward failed to start on port ${found_port}."
        kill "$pid" > /dev/null 2>&1 # Kill the failed port-forward attempt
        return 1 # Failure
    fi
}


# --- Initial Cluster/Tool State Check and Cleanup Prompt ---

echo "--- Initial Setup State Check ---"
echo "This script will set up a k3d cluster and deploy Argo CD."
echo ""
echo "It is recommended to start with a clean state to avoid conflicts."
echo "Please choose an action:"
echo "1) Clean up existing k3d cluster and Argo CD resources, then proceed."
echo "2) Proceed directly (assuming no conflicts or you've handled them manually)."
echo "3) Exit."
read -p "Enter your choice (1/2/3): " initial_choice

case $initial_choice in
    1)
        cleanup_cluster # This will clean both k3d and Argo CD
        ;;
    2)
        echo "Proceeding without initial cleanup. Be aware of potential conflicts."
        ;;
    3)
        echo "Exiting script as requested."
        exit 0
        ;;
    *)
        echo "Invalid choice. Exiting script."
        exit 1
        ;;
esac


# --- Prerequisites Check (No Installation) ---

echo "--- Checking Prerequisites ---"

echo "Checking for k3d installation..."
if ! command -v k3d &> /dev/null; then
    echo "Warning: k3d not found. Please install k3d to proceed. Refer to: https://k3d.io/v5.4.6/#installation"
    exit 1
fi
echo "k3d is installed."

echo "Checking for kubectl installation..."
if ! command -v kubectl &> /dev/null; then
    echo "Warning: kubectl not found. Please install kubectl to proceed. Refer to: https://kubernetes.io/docs/tasks/tools/install-kubectl/"
    exit 1
fi
echo "kubectl is installed."

echo "Checking for argocd CLI installation..."
if ! command -v argocd &> /dev/null; then
    echo "Warning: argocd CLI not found. Please install argocd CLI to proceed. Refer to: https://argo-cd.readthedocs.io/en/stable/getting_started/#install-argocd-cli"
    exit 1
fi
echo "argocd CLI is installed."

# --- K3d Cluster Creation or Continuation ---

echo ""
echo "--- K3d Cluster Setup ---"

# Find an available port for k3d load balancer
K3D_LB_PORT=$(find_available_port 8000 8079) # Try a different range for k3d's LB to avoid collision with Argo CD UI
if [ -z "$K3D_LB_PORT" ]; then
    echo "Error: Could not find an available port for k3d load balancer. Exiting."
    exit 1
fi
echo "K3d load balancer will use local port: ${K3D_LB_PORT}"


SKIP_CLUSTER_CREATE=false
if k3d cluster list | grep -q "${K3D_CLUSTER_NAME}"; then
    echo "A k3d cluster named '${K3D_CLUSTER_NAME}' already exists."
    echo "2) Continue the setup with the existing cluster (assuming tools are installed and cluster is healthy)."
    echo "3) Exit."
    read -p "Enter your choice (2/3): " choice_existing_cluster

    case $choice_existing_cluster in
        2)
            echo "Attempting to continue setup with existing cluster."
            kubectl config use-context k3d-"${K3D_CLUSTER_NAME}"
            if [ $? -ne 0 ]; then
                echo "Error: Could not switch to existing cluster context. Please ensure the cluster is healthy. Exiting."
                exit 1
            fi
            SKIP_CLUSTER_CREATE=true
            ;;
        3)
            echo "Exiting script as requested."
            exit 0
            ;;
        *)
            echo "Invalid choice. Exiting script."
            exit 1
            ;;
    esac
fi

if [ "$SKIP_CLUSTER_CREATE" = false ]; then
    echo "Creating k3d cluster: ${K3D_CLUSTER_NAME}..."
    # Use the dynamically found port for k3d's load balancer
    k3d cluster create "${K3D_CLUSTER_NAME}" --port "${K3D_LB_PORT}":80@loadbalancer --agents 1
    if [ $? -ne 0 ]; then
        echo "Error: k3d cluster creation failed. Please check k3d logs."
        exit 1
    fi
    echo "k3d cluster '${K3D_CLUSTER_NAME}' created successfully."
    kubectl config use-context k3d-"${K3D_CLUSTER_NAME}"
fi

# --- Argo CD Installation ---

echo ""
echo "--- Argo CD Installation ---"

echo "Installing Argo CD into namespace: ${ARGO_CD_NAMESPACE}..."
kubectl create namespace "${ARGO_CD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Warning: Namespace '${ARGO_CD_NAMESPACE}' might already exist or creation failed."
fi
kubectl apply -n "${ARGO_CD_NAMESPACE}" -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
if [ $? -ne 0 ]; then
    echo "Error: Argo CD installation failed. Please check the kubectl apply output."
    exit 1
fi
echo "Argo CD installed successfully."

# Wait for Argo CD to be ready
echo "Waiting for Argo CD server deployment to be ready (timeout 5 minutes)..."
kubectl wait --for=condition=available deployment/argocd-server -n "${ARGO_CD_NAMESPACE}" --timeout=300s
if [ $? -ne 0 ]; then
    echo "Error: Argo CD server did not become ready within the timeout. Please check 'kubectl get pods -n ${ARGO_CD_NAMESPACE}'."
    exit 1
fi
echo "Argo CD server is ready."

# --- Port-forwarding for Argo CD UI (Needed for CLI login) ---
echo "Starting temporary port-forward for Argo CD UI to enable CLI login..."
TEMP_PORT_FORWARD_PID="" # Initialize PID variable
ARGO_CD_UI_PORT_USED="" # This will hold the actual port used by port-forward
if ! start_port_forward "argocd-server" "${ARGO_CD_NAMESPACE}" 443 TEMP_PORT_FORWARD_PID; then
    echo "Error: Could not establish temporary port-forward for CLI login. Exiting."
    exit 1
fi
echo "Temporary port-forward started with PID: ${TEMP_PORT_FORWARD_PID} on port ${ARGO_CD_UI_PORT_USED}"

# --- Add an additional wait here to ensure Argo CD server is fully responsive ---
echo "Giving Argo CD server a moment to fully initialize..."
sleep 10 # Increase this if issues persist, 5-10 seconds is usually sufficient

# --- Login to Argo CD CLI ---
echo "Logging into Argo CD CLI..."
# Get the initial password for the admin user
ARGO_CD_PASSWORD=$(argocd admin initial-password -n "${ARGO_CD_NAMESPACE}")
if [ $? -ne 0 ]; then
    echo "Error: Could not retrieve Argo CD admin initial password. Ensure Argo CD server is fully up and reachable."
    kill "${TEMP_PORT_FORWARD_PID}" > /dev/null 2>&1 # Clean up temp port-forward
    exit 1
fi
echo "Argo CD admin password retrieved: ${ARGO_CD_PASSWORD}" # Display password for manual login if needed

# Log in using the port-forwarded address, CRUCIAL: use --grpc-web
argocd login localhost:"${ARGO_CD_UI_PORT_USED}" --username admin --password "${ARGO_CD_PASSWORD}" --insecure --grpc-web
if [ $? -ne 0 ]; then
    echo "Error: Argo CD CLI login failed. Please ensure port-forward is running and server is accessible, and re-run this part."
    echo "This might be due to the Argo CD server not being fully ready to accept CLI connections yet."
    echo "You can try running the script again, or manually verify Argo CD server status."
    kill "${TEMP_PORT_FORWARD_PID}" > /dev/null 2>&1 # Clean up temp port-forward
    exit 1
fi
echo "Successfully logged into Argo CD CLI."

# Kill the temporary port-forward, as argocd CLI is now authenticated
echo "Stopping temporary port-forward (PID: ${TEMP_PORT_FORWARD_PID})."
kill "${TEMP_PORT_FORWARD_PID}" > /dev/null 2>&1
wait "${TEMP_PORT_FORWARD_PID}" 2>/dev/null # Wait for the process to truly terminate

# --- Create Application Namespace ---
echo ""
echo "--- Application Namespace Setup ---"
echo "Creating application namespace: ${DEST_NAMESPACE}..."
kubectl create namespace "${DEST_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Warning: Application namespace '${DEST_NAMESPACE}' might already exist or creation failed."
fi
echo "Application namespace '${DEST_NAMESPACE}' created (or already exists)."

# --- Argo CD Application Creation ---

echo ""
echo "--- Argo CD Application Creation ---"
echo "Creating the Argo CD application: ${APP_NAME}..."

argocd app create "${APP_NAME}" \
  --repo "${REPO_URL}" \
  --path "${PATH_IN_REPO}" \
  --dest-server "${DEST_SERVER}" \
  --dest-namespace "${DEST_NAMESPACE}" \
  --sync-policy "${SYNC_POLICY}" \
  --auto-prune \
  --self-heal

if [ $? -eq 0 ]; then
    echo "Argo CD app '${APP_NAME}' was successfully created."
else
    echo "An error occurred while creating the Argo CD app. Please check the output above."
    echo "Manual Debugging Tip: You can try to log in manually: 'argocd login localhost:${ARGO_CD_UI_PORT_USED} --username admin --password ${ARGO_CD_PASSWORD} --insecure --grpc-web'"
    echo "Then retry the app creation: 'argocd app create ${APP_NAME} ...'"
    exit 1 # Exit on failure here, as app creation is critical
fi

# --- Final Port-forwarding for Argo CD UI (for user access) ---
echo ""
echo "--- Argo CD UI Access ---"
echo "Starting final port-forward for Argo CD UI. Keep this terminal open to access the UI."

FINAL_PORT_FORWARD_PID="" # Initialize PID variable for final port-forward
# Call the existing start_port_forward function which finds an available port
if ! start_port_forward "argocd-server" "${ARGO_CD_NAMESPACE}" 443 FINAL_PORT_FORWARD_PID; then
    echo "Warning: Failed to start final UI port-forward. You may need to start it manually."
    echo "Manual command: kubectl port-forward svc/argocd-server -n ${ARGO_CD_NAMESPACE} 8081:443 (replace 8081 with an available port)"
    # If the previous ARGO_CD_UI_PORT_USED was set, suggest that one as a fallback
    if [ -n "${ARGO_CD_UI_PORT_USED}" ]; then
        echo "You can try reusing port ${ARGO_CD_UI_PORT_USED}: kubectl port-forward svc/argocd-server -n ${ARGO_CD_NAMESPACE} ${ARGO_CD_UI_PORT_USED}:443"
    fi
else
    echo "Access Argo CD UI at: https://localhost:${ARGO_CD_UI_PORT_USED}"
    echo "Login with username 'admin' and password: ${ARGO_CD_PASSWORD}"
    echo "Port-forwarding started with PID: ${FINAL_PORT_FORWARD_PID}"
    echo "To stop this port-forward, use Ctrl+C in this terminal, or run: kill ${FINAL_PORT_FORWARD_PID}"
fi


# --- Kubernetes Manifests for the Application (to be placed in your Git repo) ---
echo ""
echo "--- IMPORTANT: Ensure your Git Repository has the following manifests ---"
echo "For Argo CD to deploy your application, your Git repository at"
echo "'${REPO_URL}' must contain the Kubernetes manifests at the specified path '${PATH_IN_REPO}'."
echo ""
echo "Create the directory structure: '${PATH_IN_REPO}' in your Git repository."
echo "For example, if '${PATH_IN_REPO}' is 'p3/manifests/will-playground', ensure:"
echo "   - p3/manifests/will-playground/deployment.yaml"
echo "   - p3/manifests/will-playground/service.yaml"
echo ""
echo "Content for p3/manifests/will-playground/deployment.yaml:"
cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: will-playground-deployment # Name adjusted to match the image's "will-playground"
  namespace: ${DEST_NAMESPACE} # Explicitly setting namespace
  labels:
    app: will-playground # Label adjusted to match the image's "will-playground"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: will-playground
  template:
    metadata:
      labels:
        app: will-playground
    spec:
      containers:
      - name: will-playground-container
        image: wil42/playground:v2 # Using the image from your description
        ports:
        - containerPort: 8888
EOF
echo ""
echo "Content for p3/manifests/will-playground/service.yaml:"
cat <<EOF
apiVersion: v1
kind: Service
metadata:
  name: will-playground-service # Name adjusted
  namespace: ${DEST_NAMESPACE} # Explicitly setting namespace
spec:
  selector:
    app: will-playground
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8888
  type: ClusterIP
EOF

echo ""
echo "--- Next Steps ---"
echo "1. Push the above Kubernetes manifests to your Git repository."
echo "2. Argo CD will automatically sync (due to sync-policy=Automatic)."
echo "3. You can check the application status:"
echo "   - In the Argo CD UI: https://localhost:${ARGO_CD_UI_PORT_USED}"
echo "   - From the CLI: argocd app get ${APP_NAME} --refresh --hard"
echo ""
echo "--- Clean Up ---"
echo "To clean up the k3d cluster and all Argo CD resources: run this script and choose option 1 at the start."
echo "Or manually: k3d cluster delete ${K3D_CLUSTER_NAME}"
echo "And: kubectl delete namespace ${ARGO_CD_NAMESPACE}"
echo "To stop the current UI port-forward, use Ctrl+C in this terminal, or run: kill ${FINAL_PORT_FORWARD_PID}"
echo ""