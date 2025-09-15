#!/bin/bash

# Define colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Array of tools with their names and functions
declare -A TOOLS
TOOLS["curl"]="install_curl,uninstall_curl"
TOOLS["git"]="install_git,uninstall_git"
TOOLS["docker"]="install_docker,uninstall_docker"
TOOLS["k3d"]="install_k3d,uninstall_k3d"
TOOLS["argocd"]="install_argocd,uninstall_argocd"
TOOLS["virtualbox"]="install_virtualbox,uninstall_virtualbox"
TOOLS["vagrant"]="install_vagrant,uninstall_vagrant"
TOOLS["netstat"]="install_netstat,uninstall_netstat"

# Tool display names
declare -A TOOL_NAMES
TOOL_NAMES["curl"]="Curl"
TOOL_NAMES["git"]="Git"
TOOL_NAMES["docker"]="Docker"
TOOL_NAMES["k3d"]="K3d (Kubernetes in Docker)"
TOOL_NAMES["argocd"]="Argo CD CLI"
TOOL_NAMES["virtualbox"]="VirtualBox"
TOOL_NAMES["vagrant"]="Vagrant"
TOOL_NAMES["netstat"]="netstat (net-tools)"

# Array to store tool keys in order
TOOL_ORDER=("curl" "git" "docker" "k3d" "argocd" "virtualbox" "vagrant" "netstat")

# Helper function to install a tool
function install_tool() {
    local tool_name=$1
    local install_cmd=$2
    local verify_cmd=$3

    echo -e "${GREEN}Installing $tool_name...${NC}"
    if eval "$install_cmd"; then
        echo -e "${GREEN}$tool_name installed successfully!${NC}"
        if [ -n "$verify_cmd" ]; then
            eval "$verify_cmd" || echo -e "${YELLOW}Verification command for $tool_name failed.${NC}"
        fi
    else
        echo -e "${RED}Failed to install $tool_name.${NC}"
        return 1
    fi
}

# Helper function to uninstall a tool
function uninstall_tool() {
    local tool_name=$1
    local uninstall_cmd=$2

    echo -e "${RED}Uninstalling $tool_name...${NC}"
    if eval "$uninstall_cmd"; then
        echo -e "${GREEN}$tool_name uninstalled successfully!${NC}"
    else
        echo -e "${RED}Failed to uninstall $tool_name. Some components might remain.${NC}"
        return 1
    fi
}

# --- Tool-Specific Functions ---

function install_curl() {
    install_tool "curl" "sudo apt update -y && sudo apt install -y curl" "curl --version"
}

function uninstall_curl() {
    uninstall_tool "curl" "sudo apt purge -y curl && sudo apt autoremove -y"
}

function install_git() {
    install_tool "git" "sudo apt update -y && sudo apt install -y git" "git --version"
}

function uninstall_git() {
    uninstall_tool "git" "sudo apt purge -y git && sudo apt autoremove -y"
}

function install_netstat() {
    install_tool "net-tools" "sudo apt update -y && sudo apt install -y net-tools" "netstat --version"
}

function uninstall_netstat() {
    uninstall_tool "net-tools" "sudo apt purge -y net-tools && sudo apt autoremove -y"
}

function install_docker() {
    echo -e "${GREEN}Installing Docker...${NC}"

    # Add Docker's official GPG key
    sudo apt update -y
    sudo apt install -y ca-certificates curl gnupg lsb-release
    sudo install -m 0755 -d /etc/apt/keyrings
    if curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        echo -e "${GREEN}Docker GPG key added.${NC}"
    else
        echo -e "${RED}Failed to add Docker GPG key. Aborting Docker installation.${NC}"
        return 1
    fi

    # Add the repository to Apt sources
    echo \
      "deb [arch=\"$(dpkg --print-architecture)\" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      \"$(. /etc/os-release && echo "$VERSION_CODENAME")\" stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt update -y
    if sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        echo -e "${GREEN}Docker installed successfully!${NC}"
        echo -e "${YELLOW}Adjusting Docker user groups...${NC}"
        sudo usermod -aG docker "$USER"
        echo -e "${GREEN}User '$USER' added to the 'docker' group.${NC}"
        echo -e "${YELLOW}You need to log out and log back in for group changes to take effect.${NC}"
        docker --version || echo -e "${YELLOW}Docker version command failed. Please check installation.${NC}"
    else
        echo -e "${RED}Failed to install Docker core packages.${NC}"
        return 1
    fi
}

function uninstall_docker() {
    echo -e "${RED}Attempting to stop Docker services before uninstallation...${NC}"
    sudo systemctl stop docker.service 2>/dev/null || echo -e "${YELLOW}Docker service not running or failed to stop.${NC}"
    sudo systemctl stop containerd.service 2>/dev/null || echo -e "${YELLOW}Containerd service not running or failed to stop.${NC}"
    sudo systemctl disable docker.service 2>/dev/null || echo -e "${YELLOW}Docker service not disabled.${NC}"
    sudo systemctl disable containerd.service 2>/dev/null || echo -e "${YELLOW}Containerd service not disabled.${NC}"

    echo -e "${RED}Killing any remaining Docker processes...${NC}"
    sudo killall -9 dockerd containerd containerd-shim docker-proxy 2>/dev/null || echo -e "${YELLOW}No active Docker processes to kill or insufficient permissions.${NC}"

    echo -e "${RED}Uninstalling Docker packages...${NC}"
    sudo apt purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras 2>/dev/null
    sudo apt autoremove -y --purge

    echo -e "${RED}Removing residual Docker data and configuration files...${NC}"
    sudo rm -rf /var/lib/docker 2>/dev/null
    sudo rm -rf /etc/docker 2>/dev/null
    sudo rm -rf /var/lib/containerd 2>/dev/null
    sudo rm -f /etc/apt/sources.list.d/docker.list 2>/dev/null
    sudo rm -f /etc/apt/keyrings/docker.gpg 2>/dev/null

    echo -e "${RED}Removing Docker CLI binary (if present)...${NC}"
    if command -v docker &>/dev/null; then
        local docker_bin=$(which docker)
        sudo rm -f "$docker_bin" 2>/dev/null && echo -e "${GREEN}Removed Docker CLI binary: $docker_bin${NC}" || echo -e "${YELLOW}Failed to remove Docker CLI binary: $docker_bin.${NC}"
    else
        echo -e "${YELLOW}Docker CLI binary not found in PATH.${NC}"
    fi

    if id -nG "$USER" | grep -qw "docker"; then
        echo -e "${RED}Removing user '$USER' from 'docker' group...${NC}"
        sudo gpasswd -d "$USER" docker 2>/dev/null && echo -e "${GREEN}User '$USER' removed from 'docker' group.${NC}" || echo -e "${YELLOW}Failed to remove user '$USER' from 'docker' group.${NC}"
    else
        echo -e "${YELLOW}User '$USER' is not in the 'docker' group.${NC}"
    fi

    if getent group docker >/dev/null; then
        if [ "$(getent group docker | cut -d: -f4)" == "" ]; then
            sudo delgroup docker 2>/dev/null && echo -e "${GREEN}'docker' group removed.${NC}" || echo -e "${YELLOW}'docker' group could not be removed (might not be empty or other issue).${NC}"
        else
            echo -e "${YELLOW}'docker' group still has members. Not removing.${NC}"
        fi
    fi

    echo -e "${GREEN}Docker uninstallation attempt completed.${NC}"
    echo -e "${YELLOW}Please **reboot your system** to ensure all processes are terminated and old files are truly freed.${NC}"
}

function install_argocd() {
    echo -e "${GREEN}Installing Argo CD CLI...${NC}"
    if sudo curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 && \
       sudo chmod +x /usr/local/bin/argocd; then
        echo -e "${GREEN}Argo CD CLI installed successfully!${NC}"
        argocd version --client || echo -e "${YELLOW}Argo CD CLI version command failed. Please check installation.${NC}"
    else
        echo -e "${RED}Failed to install Argo CD CLI.${NC}"
        return 1
    fi
}

function uninstall_argocd() {
    echo -e "${RED}Uninstalling Argo CD CLI...${NC}"
    if [ -f /usr/local/bin/argocd ]; then
        sudo rm -f /usr/local/bin/argocd
        echo -e "${GREEN}Argo CD CLI uninstalled successfully!${NC}"
    else
        echo -e "${YELLOW}Argo CD CLI not found in /usr/local/bin. It might not be installed.${NC}"
    fi
}

function install_virtualbox() {
    echo -e "${GREEN}Installing VirtualBox...${NC}"
    sudo apt update -y
    sudo apt install -y apt-transport-https ca-certificates curl software-properties-common

    if curl -fsSL https://www.virtualbox.org/download/oracle_vbox_2016.asc | sudo gpg --dearmor -o /usr/share/keyrings/oracle-virtualbox-2016.gpg; then
        echo -e "${GREEN}VirtualBox GPG key added.${NC}"
    else
        echo -e "${RED}Failed to add VirtualBox GPG key. Aborting VirtualBox installation.${NC}"
        return 1
    fi

    local UBUNTU_CODENAME=$(lsb_release -cs)
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] https://download.virtualbox.org/virtualbox/debian $UBUNTU_CODENAME contrib" | sudo tee /etc/apt/sources.list.d/virtualbox.list > /dev/null

    sudo apt update -y
    if sudo apt install -y virtualbox-7.0; then
        echo -e "${GREEN}VirtualBox installed successfully!${NC}"
        sudo usermod -aG vboxusers "$USER"
        echo -e "${GREEN}User '$USER' added to 'vboxusers' group.${NC}"
        echo -e "${YELLOW}You might need to log out and log back in for group changes to take effect.${NC}"
        VBoxManage --version || echo -e "${YELLOW}VBoxManage command failed. Please check installation.${NC}"
    else
        echo -e "${RED}Failed to install VirtualBox.${NC}"
        return 1
    fi
}

function uninstall_virtualbox() {
    echo -e "${RED}Uninstalling VirtualBox...${NC}"
    sudo apt purge -y virtualbox-7.0 2>/dev/null
    sudo apt autoremove -y --purge

    echo -e "${RED}Removing VirtualBox configuration files and repository...${NC}"
    sudo rm -rf ~/.config/VirtualBox 2>/dev/null
    sudo rm -rf ~/.VirtualBox 2>/dev/null
    sudo rm -f /etc/apt/sources.list.d/virtualbox.list 2>/dev/null
    sudo rm -f /usr/share/keyrings/oracle-virtualbox-2016.gpg 2>/dev/null

    if id -nG "$USER" | grep -qw "vboxusers"; then
        echo -e "${RED}Removing user '$USER' from 'vboxusers' group...${NC}"
        sudo gpasswd -d "$USER" vboxusers 2>/dev/null && echo -e "${GREEN}User '$USER' removed from 'vboxusers' group.${NC}" || echo -e "${YELLOW}Failed to remove user '$USER' from 'vboxusers' group.${NC}"
    else
        echo -e "${YELLOW}User '$USER' is not in the 'vboxusers' group.${NC}"
    fi

    if getent group vboxusers >/dev/null; then
        if [ "$(getent group vboxusers | cut -d: -f4)" == "" ]; then
            sudo delgroup vboxusers 2>/dev/null && echo -e "${GREEN}'vboxusers' group removed.${NC}" || echo -e "${YELLOW}'vboxusers' group could not be removed.${NC}"
        else
            echo -e "${YELLOW}'vboxusers' group still has members. Not removing.${NC}"
        fi
    fi

    echo -e "${GREEN}VirtualBox uninstallation attempt completed.${NC}"
}

function install_vagrant() {
    echo -e "${GREEN}Installing Vagrant from HashiCorp APT repository...${NC}"

    if wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg; then
        echo -e "${GREEN}HashiCorp GPG key added.${NC}"
    else
        echo -e "${RED}Failed to add HashiCorp GPG key. Aborting Vagrant installation.${NC}"
        return 1
    fi

    local UBUNTU_CODENAME=$(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs)
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $UBUNTU_CODENAME main" | sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
    echo -e "${GREEN}HashiCorp APT repository added.${NC}"

    sudo apt update -y
    if sudo apt install -y vagrant; then
        echo -e "${GREEN}Vagrant installed successfully!${NC}"
        vagrant --version || echo -e "${YELLOW}Vagrant version command failed. Please check installation.${NC}"
    else
        echo -e "${RED}Failed to install Vagrant from repository.${NC}"
        return 1
    fi
}

function uninstall_vagrant() {
    echo -e "${RED}Uninstalling Vagrant...${NC}"
    sudo apt purge -y vagrant 2>/dev/null
    sudo apt autoremove -y --purge

    echo -e "${RED}Removing residual Vagrant configuration, data, and HashiCorp repository...${NC}"
    rm -rf ~/.vagrant.d 2>/dev/null && echo -e "${GREEN}Removed ~/.vagrant.d directory.${NC}" || echo -e "${YELLOW}Failed to remove ~/.vagrant.d or directory not found.${NC}"

    sudo rm -f /etc/apt/sources.list.d/hashicorp.list 2>/dev/null
    sudo rm -f /usr/share/keyrings/hashicorp-archive-keyring.gpg 2>/dev/null
    echo -e "${GREEN}HashiCorp repository and GPG key removed.${NC}"

    echo -e "${GREEN}Vagrant uninstallation attempt completed.${NC}"
}

function install_k3d() {
    echo -e "${GREEN}Installing k3d...${NC}"
    if curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash; then
        echo -e "${GREEN}k3d installed successfully!${NC}"
        k3d --version || echo -e "${YELLOW}k3d version command failed. Please check installation.${NC}"
    else
        echo -e "${RED}Failed to install k3d.${NC}"
        return 1
    fi
}

function uninstall_k3d() {
    echo -e "${RED}Uninstalling k3d...${NC}"
    if [ -f /usr/local/bin/k3d ]; then
        sudo rm -f /usr/local/bin/k3d
        echo -e "${GREEN}k3d uninstalled successfully!${NC}"
    else
        echo -e "${YELLOW}k3d not found in /usr/local/bin. It might not be installed or is in a different location.${NC}"
    fi
    echo -e "${YELLOW}Checking for and removing any k3d created Docker resources...${NC}"
    docker volume ls -q -f "name=k3d-" | xargs -r docker volume rm 2>/dev/null
    docker network ls -q -f "name=k3d-" | xargs -r docker network rm 2>/dev/null
    echo -e "${GREEN}Attempted to remove k3d related Docker volumes and networks.${NC}"
}

# Function to read a single key with proper handling
function read_key() {
    local key
    IFS= read -rsn1 key
    
    # Handle escape sequences
    if [[ $key == $'\x1b' ]]; then
        # Read the next two characters to get the full escape sequence
        read -rsn2 -t 0.1 key
    fi
    
    echo "$key"
}

# Function to show multi-select menu
function show_multi_select_menu() {
    local action=$1  # "install" or "uninstall"
    local -a selected=()
    local current=0
    local total=${#TOOL_ORDER[@]}
    
    # Initialize selection array
    for i in "${TOOL_ORDER[@]}"; do
        selected+=("false")
    done
    
    while true; do
        clear
        echo -e "${CYAN}=== Ubuntu Development Tools Manager - Multi-Select ${action^^} ===${NC}"
        echo -e "${YELLOW}Use ARROW KEYS to navigate, SPACE to select/deselect, ENTER to proceed, q to exit${NC}"
        echo ""
        
        # Display tools with selection status
        for i in "${!TOOL_ORDER[@]}"; do
            local tool_key="${TOOL_ORDER[$i]}"
            local tool_name="${TOOL_NAMES[$tool_key]}"
            local prefix="   "
            local suffix=""
            
            # Show cursor
            if [ $i -eq $current ]; then
                prefix="${BLUE}> ${NC}"
            fi
            
            # Show selection status
            if [ "${selected[$i]}" = "true" ]; then
                suffix="${GREEN} [✓]${NC}"
            else
                suffix=" [ ]"
            fi
            
            echo -e "$prefix$tool_name$suffix"
        done
        
        echo ""
        echo -e "${YELLOW}Selected tools will be ${action}ed. Press ENTER to proceed or 'q' to exit.${NC}"
        
        # Read key input
        key=$(read_key)
        
        case "$key" in
            '[A') # Up arrow
                ((current > 0)) && ((current--))
                ;;
            '[B') # Down arrow  
                ((current < total-1)) && ((current++))
                ;;
            ' ') # Space
                if [ "${selected[$current]}" = "true" ]; then
                    selected[$current]="false"
                else
                    selected[$current]="true"
                fi
                ;;
            '') # Enter
                local selected_tools=()
                for i in "${!TOOL_ORDER[@]}"; do
                    if [ "${selected[$i]}" = "true" ]; then
                        selected_tools+=("${TOOL_ORDER[$i]}")
                    fi
                done
                
                if [ ${#selected_tools[@]} -eq 0 ]; then
                    echo -e "${YELLOW}No tools selected. Press any key to continue...${NC}"
                    read -rsn1
                else
                    execute_batch_action "$action" "${selected_tools[@]}"
                fi
                return 0
                ;;
            'q'|'Q') # Quit
                return 1
                ;;
        esac
    done
}

# Function to execute batch actions
function execute_batch_action() {
    local action=$1
    shift
    local tools=("$@")
    
    echo -e "${CYAN}=== Executing ${action} for selected tools ===${NC}"
    echo ""
    
    # Show selected tools
    echo -e "${YELLOW}Selected tools:${NC}"
    for tool in "${tools[@]}"; do
        echo -e "  - ${TOOL_NAMES[$tool]}"
    done
    echo ""
    
    read -p "Do you want to proceed? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        return 0
    fi
    
    echo ""
    echo -e "${CYAN}=== Starting batch ${action} ===${NC}"
    
    local success_count=0
    local total_count=${#tools[@]}
    
    for tool in "${tools[@]}"; do
        echo ""
        echo -e "${BLUE}--- Processing: ${TOOL_NAMES[$tool]} ---${NC}"
        
        local functions_str="${TOOLS[$tool]}"
        local install_func="${functions_str%%,*}"
        local uninstall_func="${functions_str##*,}"
        
        if [ "$action" = "install" ]; then
            if $install_func; then
                ((success_count++))
                echo -e "${GREEN}✓ ${TOOL_NAMES[$tool]} ${action} completed successfully${NC}"
            else
                echo -e "${RED}✗ ${TOOL_NAMES[$tool]} ${action} failed${NC}"
            fi
        else
            if $uninstall_func; then
                ((success_count++))
                echo -e "${GREEN}✓ ${TOOL_NAMES[$tool]} ${action} completed successfully${NC}"
            else
                echo -e "${RED}✗ ${TOOL_NAMES[$tool]} ${action} failed${NC}"
            fi
        fi
    done
    
    echo ""
    echo -e "${CYAN}=== Batch ${action} Summary ===${NC}"
    echo -e "${GREEN}Successful: $success_count/$total_count${NC}"
    echo -e "${RED}Failed: $((total_count - success_count))/$total_count${NC}"
    
    if [ $success_count -lt $total_count ]; then
        echo -e "${YELLOW}Some operations failed. Please check the output above for details.${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}Press any key to continue...${NC}"
    read -rsn1
}

# Main menu function
function show_main_menu() {
    clear
    echo -e "${CYAN}=== Ubuntu Development Tools Manager ===${NC}"
    echo ""
    echo -e "${YELLOW}Available Tools:${NC}"
    for tool_key in "${TOOL_ORDER[@]}"; do
        echo -e "  • ${TOOL_NAMES[$tool_key]}"
    done
    echo ""
    echo -e "${YELLOW}Choose an action:${NC}"
    echo "  1) Install Multiple Tools"
    echo "  2) Uninstall Multiple Tools"
    echo "  3) Exit"
    echo ""
}

# Main loop
while true; do
    show_main_menu
    read -p "Enter your choice (1-3): " choice
    
    case "$choice" in
        1)
            show_multi_select_menu "install"
            ;;
        2)
            show_multi_select_menu "uninstall"
            ;;
        3)
            echo -e "${YELLOW}Exiting. Goodbye!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid choice. Please enter 1, 2, or 3.${NC}"
            read -p "Press any key to continue..." -rsn1
            ;;
    esac
done