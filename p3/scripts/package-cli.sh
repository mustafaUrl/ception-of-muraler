#!/bin/bash

# Define colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

function install_tool() {
    local tool_name=$1
    local install_cmd=$2
    local verify_cmd=$3

    echo -e "${GREEN}Installing $tool_name...${NC}"
    if eval "$install_cmd"; then # Execute the installation command and check its exit status
        echo -e "${GREEN}$tool_name installed successfully!${NC}"
        if [ -n "$verify_cmd" ]; then # Check if a verification command is provided
            eval "$verify_cmd" || echo -e "${YELLOW}Verification command for $tool_name failed.${NC}"
        fi
    else
        echo -e "${RED}Failed to install $tool_name.${NC}"
        return 1 # Indicate failure
    fi
}

function uninstall_tool() {
    local tool_name=$1
    local uninstall_cmd=$2

    echo -e "${RED}Uninstalling $tool_name...${NC}"
    if eval "$uninstall_cmd"; then # Execute the uninstallation command and check its exit status
        echo -e "${GREEN}$tool_name uninstalled successfully!${NC}"
    else
        echo -e "${RED}Failed to uninstall $tool_name. Some components might remain.${NC}"
        return 1 # Indicate failure
    fi
}

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
        # Add current user to the docker group
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
    # Use -f for force removal to avoid "No such file or directory" errors if they don't exist
    sudo rm -rf /var/lib/docker 2>/dev/null
    sudo rm -rf /etc/docker 2>/dev/null # Remove /etc/docker directory
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

    # Remove the current user from the docker group
    if id -nG "$USER" | grep -qw "docker"; then
        echo -e "${RED}Removing user '$USER' from 'docker' group...${NC}"
        sudo gpasswd -d "$USER" docker 2>/dev/null && echo -e "${GREEN}User '$USER' removed from 'docker' group.${NC}" || echo -e "${YELLOW}Failed to remove user '$USER' from 'docker' group.${NC}"
    else
        echo -e "${YELLOW}User '$USER' is not in the 'docker' group.${NC}"
    fi

    # Remove the docker group if it's empty
    if getent group docker >/dev/null; then
        if [ "$(getent group docker | cut -d: -f4)" == "" ]; then # Check if group has no members
            sudo delgroup docker 2>/dev/null && echo -e "${GREEN}'docker' group removed.${NC}" || echo -e "${YELLOW}'docker' group could not be removed (might not be empty or other issue).${NC}"
        else
            echo -e "${YELLOW}'docker' group still has members. Not removing.${NC}"
        fi
    fi

    echo -e "${GREEN}Docker uninstallation attempt completed.${NC}"
    echo -e "${YELLOW}Please **reboot your system** to ensure all processes are terminated and old files are truly freed.${NC}"
}


function install_k3d() {
    echo -e "${GREEN}Installing k3d...${NC}"
    # Install k3d from its official script
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
    # k3d's uninstallation is usually just removing the binary if installed via script
    if [ -f /usr/local/bin/k3d ]; then
        sudo rm -f /usr/local/bin/k3d
        echo -e "${GREEN}k3d uninstalled successfully!${NC}"
    else
        echo -e "${YELLOW}k3d not found in /usr/local/bin. It might not be installed or is in a different location.${NC}"
    fi
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
    # VirtualBox installation steps (adding repo, key, then installing)
    sudo apt update -y
    sudo apt install -y apt-transport-https ca-certificates curl software-properties-common

    # Add VirtualBox GPG key
    if curl -fsSL https://www.virtualbox.org/download/oracle_vbox_2016.asc | sudo gpg --dearmor -o /usr/share/keyrings/oracle-virtualbox-2016.gpg; then
        echo -e "${GREEN}VirtualBox GPG key added.${NC}"
    else
        echo -e "${RED}Failed to add VirtualBox GPG key. Aborting VirtualBox installation.${NC}"
        return 1
    fi

    # Add VirtualBox repository
    # Use lsb_release -cs to get the codename (e.g., 'jammy' for Ubuntu 22.04)
    local UBUNTU_CODENAME=$(lsb_release -cs)
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] https://download.virtualbox.org/virtualbox/debian $UBUNTU_CODENAME contrib" | sudo tee /etc/apt/sources.list.d/virtualbox.list > /dev/null

    sudo apt update -y
    if sudo apt install -y virtualbox-7.0; then # Adjust version if needed
        echo -e "${GREEN}VirtualBox installed successfully!${NC}"
        # Add current user to vboxusers group
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
    sudo apt purge -y virtualbox-7.0 2>/dev/null # Adjust version if needed
    sudo apt autoremove -y --purge

    echo -e "${RED}Removing VirtualBox configuration files and repository...${NC}"
    sudo rm -rf ~/.config/VirtualBox 2>/dev/null # User specific config
    sudo rm -rf ~/.VirtualBox 2>/dev/null      # Older user specific config
    sudo rm -f /etc/apt/sources.list.d/virtualbox.list 2>/dev/null
    sudo rm -f /usr/share/keyrings/oracle-virtualbox-2016.gpg 2>/dev/null

    # Remove the current user from vboxusers group
    if id -nG "$USER" | grep -qw "vboxusers"; then
        echo -e "${RED}Removing user '$USER' from 'vboxusers' group...${NC}"
        sudo gpasswd -d "$USER" vboxusers 2>/dev/null && echo -e "${GREEN}User '$USER' removed from 'vboxusers' group.${NC}" || echo -e "${YELLOW}Failed to remove user '$USER' from 'vboxusers' group.${NC}"
    else
        echo -e "${YELLOW}User '$USER' is not in the 'vboxusers' group.${NC}"
    fi

    # Optionally, remove the vboxusers group if empty
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
    echo -e "${GREEN}Installing Vagrant...${NC}"
    # Robustly find the latest Vagrant .deb package URL
    # This uses jq for more reliable JSON parsing. If jq isn't installed, it falls back to grep/cut.
    local LATEST_VAGRANT_URL
    if command -v jq &>/dev/null; then
        LATEST_VAGRANT_URL=$(curl -s https://api.github.com/repos/hashicorp/vagrant/releases/latest | jq -r '.assets[] | select(.name | ends_with("_linux_amd64.deb")) | .browser_download_url' | head -n 1)
    else
        echo -e "${YELLOW}jq not found. Falling back to less robust URL parsing for Vagrant. Consider installing jq (sudo apt install -y jq).${NC}"
        LATEST_VAGRANT_URL=$(curl -s https://api.github.com/repos/hashicorp/vagrant/releases/latest | grep "browser_download_url.*_linux_amd64.deb" | sed -E 's/.*"([^"]+)".*/\1/' | head -n 1)
    fi


    if [ -z "$LATEST_VAGRANT_URL" ]; then
        echo -e "${RED}Could not find the latest Vagrant .deb package URL. Aborting installation.${NC}"
        return 1
    fi

    echo "Downloading Vagrant from: $LATEST_VAGRANT_URL"
    mkdir -p /tmp/vagrant_install
    cd /tmp/vagrant_install || { echo -e "${RED}Failed to create/enter temporary directory for Vagrant. Aborting.${NC}"; return 1; }

    if curl -sSL -o vagrant.deb "$LATEST_VAGRANT_URL"; then
        if sudo apt install -y ./vagrant.deb; then
            echo -e "${GREEN}Vagrant installed successfully!${NC}"
            vagrant --version || echo -e "${YELLOW}Vagrant version command failed. Please check installation.${NC}"
        else
            echo -e "${RED}Failed to install Vagrant .deb package.${NC}"
            return 1
        fi
    else
        echo -e "${RED}Failed to download Vagrant .deb package.${NC}"
        return 1
    fi

    cd - > /dev/null # Go back to the previous directory
    rm -rf /tmp/vagrant_install # Clean up temp files
}

function uninstall_vagrant() {
    echo -e "${RED}Uninstalling Vagrant...${NC}"
    sudo apt purge -y vagrant 2>/dev/null
    sudo apt autoremove -y --purge

    echo -e "${RED}Removing residual Vagrant configuration and data...${NC}"
    # Vagrant stores boxes and configs in ~/.vagrant.d
    rm -rf ~/.vagrant.d 2>/dev/null && echo -e "${GREEN}Removed ~/.vagrant.d directory.${NC}" || echo -e "${YELLOW}Failed to remove ~/.vagrant.d or directory not found.${NC}"

    echo -e "${GREEN}Vagrant uninstallation attempt completed.${NC}"
}


# Main menu
echo "Welcome to the Ubuntu Development Tools Manager!"
echo "Please choose an action for the following tools:"
echo "  1) Install/Uninstall **curl**"
echo "  2) Install/Uninstall **git**"
echo "  3) Install/Uninstall **Docker**"
echo "  4) Install/Uninstall **k3d**"
echo "  5) Install/Uninstall **Argo CD CLI**"
echo "  6) Install/Uninstall **VirtualBox**"
echo "  7) Install/Uninstall **Vagrant**"
echo "  8) Exit"

read -p "Enter your choice (1-8): " main_choice

case "$main_choice" in
    1)
        echo "Choose an action for curl:"
        echo "  1) Install curl"
        echo "  2) Uninstall curl"
        read -p "Enter your choice (1/2): " sub_choice
        if [ "$sub_choice" == "1" ]; then install_curl; elif [ "$sub_choice" == "2" ]; then uninstall_curl; else echo -e "${RED}Invalid choice.${NC}"; fi
        ;;
    2)
        echo "Choose an action for git:"
        echo "  1) Install git"
        echo "  2) Uninstall git"
        read -p "Enter your choice (1/2): " sub_choice
        if [ "$sub_choice" == "1" ]; then install_git; elif [ "$sub_choice" == "2" ]; then uninstall_git; else echo -e "${RED}Invalid choice.${NC}"; fi
        ;;
    3)
        echo "Choose an action for Docker:"
        echo "  1) Install Docker"
        echo "  2) Uninstall Docker"
        read -p "Enter your choice (1/2): " sub_choice
        if [ "$sub_choice" == "1" ]; then install_docker; elif [ "$sub_choice" == "2" ]; then uninstall_docker; else echo -e "${RED}Invalid choice.${NC}"; fi
        ;;
    4)
        echo "Choose an action for k3d:"
        echo "  1) Install k3d"
        echo "  2) Uninstall k3d"
        read -p "Enter your choice (1/2): " sub_choice
        if [ "$sub_choice" == "1" ]; then install_k3d; elif [ "$sub_choice" == "2" ]; then uninstall_k3d; else echo -e "${RED}Invalid choice.${NC}"; fi
        ;;
    5)
        echo "Choose an action for Argo CD CLI:"
        echo "  1) Install Argo CD CLI"
        echo "  2) Uninstall Argo CD CLI"
        read -p "Enter your choice (1/2): " sub_choice
        if [ "$sub_choice" == "1" ]; then install_argocd; elif [ "$sub_choice" == "2" ]; then uninstall_argocd; else echo -e "${RED}Invalid choice.${NC}"; fi
        ;;
    6)
        echo "Choose an action for VirtualBox:"
        echo "  1) Install VirtualBox"
        echo "  2) Uninstall VirtualBox"
        read -p "Enter your choice (1/2): " sub_choice
        if [ "$sub_choice" == "1" ]; then install_virtualbox; elif [ "$sub_choice" == "2" ]; then uninstall_virtualbox; else echo -e "${RED}Invalid choice.${NC}"; fi
        ;;
    7)
        echo "Choose an action for Vagrant:"
        echo "  1) Install Vagrant"
        echo "  2) Uninstall Vagrant"
        read -p "Enter your choice (1/2): " sub_choice
        if [ "$sub_choice" == "1" ]; then install_vagrant; elif [ "$sub_choice" == "2" ]; then uninstall_vagrant; else echo -e "${RED}Invalid choice.${NC}"; fi
        ;;
    8)
        echo "Exiting the script. Goodbye!"
        exit 0
        ;;
    *)
        echo -e "${RED}Invalid main choice. Please enter a number between 1 and 8.${NC}"
        exit 1
        ;;
esac