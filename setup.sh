#!/bin/bash
# --- Pre-flight Check for Interactivity ---
if ! [ -t 0 ]; then
    echo -e "\n\e[1;31m[ERROR] This script must be run in an interactive terminal.\e[0m"
    echo -e "It cannot be piped directly from curl. Please run it using one of the following methods:"
    echo -e "  1. Download and execute:"
    echo -e "     \e[1;32mcurl -sSL https://raw.githubusercontent.com/Invinciblefluffy/scripts/main/setup.sh -o setup.sh && chmod +x setup.sh && ./setup.sh\e[0m"
    echo -e "  2. Clone the repository and execute:"
    echo -e "     \e[1;32mgit clone https://github.com/Invinciblefluffy/scripts.git && cd scripts && ./setup.sh\e[0m"
    exit 1
fi

# Interactive VPS Setup Script
# ============================
#
# This script will guide you through the setup of your new VPS.
# It is designed to be run on a fresh Debian-based system (e.g., Ubuntu, Debian).
#
# WARNING: Run this on a fresh VPS. It is not guaranteed to be idempotent.

# --- Stop on Error ---
set -e

# --- Helper Functions ---
print_info() {
    echo -e "\n\e[1;34m[INFO] $1\e[0m"
}

print_success() {
    echo -e "\e[1;32m[SUCCESS] $1\e[0m"
}

print_warn() {
    echo -e "\e[1;33m[WARN] $1\e[0m"
}

# Asks a yes/no question. Default is yes.
ask_yes_no() {
    local question="$1"
    local default_answer="y"
    local answer

    read -p "$question [Y/n]: " answer
    answer=${answer:-$default_answer} # Default to 'y' if empty
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        return 0 # Success (yes)
    else
        return 1 # Failure (no)
    fi
}

# --- Main Setup Functions ---

# --- Collect User Information ---
collect_user_input() {
    print_info "Starting interactive setup. Please provide the following information."

    # SSH Port
    read -p "Enter the SSH port you want to use [22]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}

    # New User
    if ask_yes_no "Do you want to create a new user with sudo privileges? (Recommended)"; then
        read -p "Enter the username for the new user: " NEW_USER_NAME
        while [ -z "$NEW_USER_NAME" ]; do
            print_warn "Username cannot be empty."
            read -p "Enter the username for the new user: " NEW_USER_NAME
        done
        # We will create the user later in the script
        CREATE_NEW_USER="true"
    else
        CREATE_NEW_USER="false"
        print_warn "Continuing setup as root. This is not recommended for production."
    fi

    # Fail2Ban
    if ask_yes_no "Do you want to install Fail2Ban to protect against brute-force attacks?"; then
        INSTALL_FAIL2BAN="true"
        F2B_MAX_RETRY=5
        F2B_BAN_TIME=3600
        print_info "Fail2Ban will be configured with default values: maxretry=$F2B_MAX_RETRY, bantime=$F2B_BAN_TIME seconds."
    else
        INSTALL_FAIL2BAN="false"
    fi

    # BBR
    if ask_yes_no "Do you want to enable TCP BBR for better network performance?"; then
        ENABLE_BBR="true"
    else
        ENABLE_BBR="false"
    fi
    
    # SSL with acme.sh
    if ask_yes_no "Do you want to install acme.sh for SSL certificates?"; then
        INSTALL_ACME_SH="true"
        read -p "Enter your domain name (e.g., example.com): " ACME_DOMAIN
        while [ -z "$ACME_DOMAIN" ]; do
            print_warn "Domain name cannot be empty."
            read -p "Enter your domain name: " ACME_DOMAIN
        done
        read -p "Enter your email for Let's Encrypt notifications: " ACME_EMAIL
        while [ -z "$ACME_EMAIL" ]; do
            print_warn "Email cannot be empty."
            read -p "Enter your email: " ACME_EMAIL
        done
    else
        INSTALL_ACME_SH="false"
    fi
    
    # Docker
    if ask_yes_no "Do you want to install Docker and Docker Compose?"; then
        INSTALL_DOCKER="true"
    else
        INSTALL_DOCKER="false"
    fi
}

update_system() {
    print_info "Updating and upgrading system packages..."
    # Set frontend to noninteractive and force keeping old config files to prevent interactive prompts
    sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=\"--force-confold\" upgrade
    sudo apt-get install -y kitty-terminfo apt-transport-https ca-certificates curl gnupg lsb-release
    print_success "System updated."
}

setup_new_user() {
    if [ "$CREATE_NEW_USER" = "true" ]; then
        print_info "Creating new user '$NEW_USER_NAME'..."
        if id "$NEW_USER_NAME" &>/dev/null; then
            print_warn "User '$NEW_USER_NAME' already exists. Skipping creation."
            USER_NAME=$NEW_USER_NAME
        else
            sudo adduser --disabled-password --gecos "" "$NEW_USER_NAME"
            sudo usermod -aG sudo "$NEW_USER_NAME"
            print_success "User '$NEW_USER_NAME' created and added to sudo group."
            print_info "You will need to set a password or add an SSH key for this user."
            USER_NAME=$NEW_USER_NAME # For Docker setup
        fi
    else
        # If not creating a user, but docker needs a user, we ask for it
        if [ "$INSTALL_DOCKER" = "true" ]; then
             read -p "Which existing user should be added to the docker group? (e.g., your non-root user): " USER_NAME
        fi
    fi
}


configure_ssh() {
    print_info "Configuring SSH on port $SSH_PORT..."
    
    # Backup original config
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    print_info "Backed up sshd_config to /etc/ssh/sshd_config.bak"

    sudo sed -i -E "s/^#?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
    sudo sed -i -E "s/^#?PermitRootLogin .*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
    sudo sed -i -E "s/^#?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
    sudo sed -i -E "s/^#?PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
    sudo sed -i -E "s/^#?UsePAM .*/UsePAM no/" /etc/ssh/sshd_config

    sudo systemctl restart ssh
    print_success "SSH configured on port $SSH_PORT. Make sure to allow this port in your firewall!"
}

setup_iptables() {
    print_info "Installing iptables-persistent and setting up firewall rules..."
    
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
    sudo apt-get install -y iptables-persistent

    # Detect primary network interface
    PRIMARY_INTERFACE=$(ip -4 route show default | sed -ne 's/.* dev \([^ ]*\) .*/\1/p')
    if [ -z "$PRIMARY_INTERFACE" ]; then
        print_warn "Could not detect primary network interface. Docker rules may need manual adjustment."
        # Fallback to eth0
        PRIMARY_INTERFACE="eth0"
    else
        print_info "Detected primary network interface: $PRIMARY_INTERFACE"
    fi

    print_info "Flushing existing iptables rules..."
    sudo iptables -F && sudo iptables -X && sudo iptables -Z

    sudo iptables -P INPUT ACCEPT
    sudo iptables -P FORWARD ACCEPT
    sudo iptables -P OUTPUT ACCEPT

    print_info "The following default INPUT rules will be applied:"
    echo " - Allow all loopback traffic (localhost)"
    echo " - Allow all established, related traffic"
    echo " - Allow SSH on port $SSH_PORT"
    echo " - Allow HTTP (80) and HTTPS (443)"
    echo " - Allow Ping (ICMP)"
    echo "The default INPUT policy will be set to DROP."

    # Custom ports
    read -p "Enter any additional TCP ports to allow (space-separated, e.g., '8080 8888'): " custom_tcp_ports
    read -p "Enter any additional UDP ports to allow (space-separated, e.g., '51820'): " custom_udp_ports

    print_info "Applying new iptables rules..."
    # Allow localhost
    sudo iptables -A INPUT -i lo -j ACCEPT
    sudo iptables -A OUTPUT -o lo -j ACCEPT

    # Allow established/related connections
    sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # Allow SSH
    sudo iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT

    # Allow HTTP/HTTPS
    sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT

    # Allow ping (ICMP)
    sudo iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
    
    # Custom TCP ports
    if [ -n "$custom_tcp_ports" ]; then
        for port in $custom_tcp_ports; do
            sudo iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            print_info "Allowed incoming TCP on port $port"
        done
    fi

    # Custom UDP ports
    if [ -n "$custom_udp_ports" ]; then
        for port in $custom_udp_ports; do
            sudo iptables -A INPUT -p udp --dport "$port" -j ACCEPT
            print_info "Allowed incoming UDP on port $port"
        done
    fi



    # Finally, drop all other incoming traffic
    print_info "Setting default INPUT policy to DROP."
    sudo iptables -P INPUT DROP

    print_info "Saving iptables rules..."
    sudo iptables-save > /etc/iptables/rules.v4

    print_success "iptables firewall configured and rules are persistent."
}

install_fail2ban() {
    if [ "$INSTALL_FAIL2BAN" != "true" ]; then
        print_info "Skipping Fail2Ban installation."
        return
    fi
    print_info "Setting up Fail2Ban..."
    sudo apt-get install -y fail2ban
    
    JAIL_OVERRIDE_FILE="/etc/fail2ban/jail.d/sshd-custom.conf"
    sudo mkdir -p /etc/fail2ban/jail.d
    sudo bash -c "cat > ${JAIL_OVERRIDE_FILE}" <<EOF
[sshd]
enabled = true
port = $SSH_PORT
maxretry = $F2B_MAX_RETRY
bantime = $F2B_BAN_TIME
EOF
    sudo systemctl restart fail2ban
    print_success "Fail2Ban has been configured."
}

install_docker() {
    if [ "$INSTALL_DOCKER" != "true" ]; then
        print_info "Skipping Docker installation."
        return
    fi
    print_info "Installing Docker..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io

    print_info "Installing Docker Compose..."
    LATEST_COMPOSE=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep "tag_name" | cut -d\" -f4)
    sudo curl -L "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    
    if [ -n "$USER_NAME" ]; then
        if id "$USER_NAME" &>/dev/null; then
            sudo usermod -aG docker "$USER_NAME"
            print_success "User $USER_NAME added to the docker group. You will need to log out and back in for this to take effect."
        else
            print_warn "User '$USER_NAME' specified for Docker does not exist. Skipping."
        fi
    else
        print_warn "No user was specified to be added to the docker group."
    fi
    print_success "Docker and Docker Compose installed."
}

install_acme_sh() {
    if [ "$INSTALL_ACME_SH" != "true" ]; then
        print_info "Skipping SSL certificate installation."
        return
    fi

    print_info "Preparing for SSL certificate installation..."
    sudo apt-get install -y socat curl

    curl https://get.acme.sh | sudo sh -s email="$ACME_EMAIL"
    ACME_SH_PATH="/root/.acme.sh/acme.sh"

    print_info "Setting default CA to Let's Encrypt..."
    sudo "$ACME_SH_PATH" --set-default-ca --server letsencrypt

    print_info "Issuing SSL certificate for $ACME_DOMAIN... (This may take a moment)"
    sudo "$ACME_SH_PATH" --issue --standalone -d "$ACME_DOMAIN" --keylength ec-256
    
    print_success "SSL certificate process completed for $ACME_DOMAIN."
    print_info "Your certificate is located in /root/.acme.sh/$ACME_DOMAIN/"
}

enable_bbr() {
    if [ "$ENABLE_BBR" != "true" ]; then
        print_info "Skipping BBR configuration."
        return
    fi
    print_info "Enabling TCP BBR..."
    if grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf && grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        print_info "BBR settings already exist in /etc/sysctl.conf."
    else
        sudo bash -c "cat >> /etc/sysctl.conf" <<EOF

# Enable BBR Congestion Control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    fi
    sudo sysctl -p
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        print_success "BBR is enabled."
    else
        print_warn "BBR may not be enabled correctly. Please check your kernel version (4.9+ required)."
    fi
}

# --- Run Setup ---
main() {
    collect_user_input
    
    update_system
    setup_new_user
    configure_ssh
    install_fail2ban
    enable_bbr
    setup_iptables # iptables runs before docker installation
    install_docker # Docker is installed after iptables is set up
    install_acme_sh

    print_info "-------------------- SETUP COMPLETE --------------------"
    print_warn "ACTION REQUIRED: A reboot is highly recommended."
    if [ "$CREATE_NEW_USER" = "true" ]; then
         print_warn "Log out from root, and log back in as '$NEW_USER_NAME'."
    fi
    echo "To reboot now, run: sudo reboot"
}

main