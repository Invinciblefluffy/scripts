#!/bin/bash
# VPS Setup Script
# =================
#
# Usage:
# 1. Create a .env file with your configuration (you can use .env.example as a template).
#    Uncomment and set the variables for the features you want to use.
# 2. Make sure the .env file is in the same directory where you will run the script.
# 3. Run on the server:
#    curl -sSL https://your-github-repo/setup.sh | bash
#
# The script will automatically load variables from the .env file.
# If a variable is commented out, a default value will be used if available.
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

# --- Load Environment Variables ---
load_env() {
    if [ -f ".env" ]; then
        print_info "Loading environment variables from .env file..."
        set -a
        source .env
        set +a
        print_success ".env file loaded."
    else
        print_warn ".env file not found. Using script defaults."
    fi
}

# --- Main Setup Functions ---

update_system() {
    print_info "Updating and upgrading system packages..."
    # Set frontend to noninteractive and force keeping old config files to prevent interactive prompts
    sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confold" upgrade
    sudo apt-get install -y kitty-terminfo apt-transport-https ca-certificates curl gnupg lsb-release
    print_success "System updated."
}

configure_ssh() {
    print_info "Configuring SSH..."
    if [ -z "$SSH_PORT" ]; then
        print_warn "SSH_PORT is not set. Using default 22."
        SSH_PORT=22
    fi

    # Update sshd_config
    sudo sed -i -E "s/^#?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
    sudo sed -i -E "s/^#?PermitRootLogin .*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
    sudo sed -i -E "s/^#?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
    sudo sed -i -E "s/^#?PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
    sudo sed -i -E "s/^#?UsePAM .*/UsePAM no/" /etc/ssh/sshd_config

    sudo systemctl restart ssh
    print_success "SSH configured on port $SSH_PORT."
}

setup_iptables() {
    print_info "Installing iptables-persistent and setting up firewall rules..."
    
    # Install iptables-persistent to save rules
    # Pre-seed the installation to avoid interactive prompts
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
    sudo apt-get install -y iptables-persistent

    print_info "Flushing existing iptables rules..."
    sudo iptables -F
    sudo iptables -X
    sudo iptables -Z

    print_info "Setting default policies..."
    # Temporarily accept all INPUT to avoid being locked out during setup
    sudo iptables -P INPUT ACCEPT
    sudo iptables -P FORWARD ACCEPT
    sudo iptables -P OUTPUT ACCEPT

    print_info "Applying new iptables rules..."
    # Allow localhost
    sudo iptables -A INPUT -i lo -j ACCEPT
    sudo iptables -A OUTPUT -o lo -j ACCEPT

    # Allow established/related connections
    sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # Allow SSH (port from .env)
    if [ -z "$SSH_PORT" ]; then
        print_warn "SSH_PORT is not set. Using default 22 for iptables rule."
        SSH_PORT=22
    fi
    sudo iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT

    # Allow HTTP/HTTPS
    sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT

    # Allow ping (ICMP)
    sudo iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

    # Finally, drop all other incoming traffic
    print_info "Setting default INPUT policy to DROP."
    sudo iptables -P INPUT DROP

    # Save the rules
    print_info "Saving iptables rules..."
    sudo iptables-save > /etc/iptables/rules.v4

    print_success "iptables firewall configured and rules are persistent."
}

install_fail2ban() {
    print_info "Setting up Fail2Ban..."

    if ! command -v fail2ban-client &> /dev/null; then
        sudo apt-get install -y fail2ban
    else
        print_info "Fail2Ban is already installed."
    fi

    # Fail2Ban setup for SSH
    JAIL_OVERRIDE_FILE="/etc/fail2ban/jail.d/sshd-custom.conf"
    print_info "Configuring Fail2Ban for SSH..."
    sudo mkdir -p /etc/fail2ban/jail.d
    sudo bash -c "cat > ${JAIL_OVERRIDE_FILE}" <<EOF
[sshd]
enabled = true
port = $SSH_PORT
maxretry = ${F2B_MAX_RETRY:-5}
bantime = ${F2B_BAN_TIME:-3600}
EOF

    sudo systemctl restart fail2ban
    print_success "Fail2Ban has been configured."
}

install_docker() {
    if command -v docker &> /dev/null; then
        print_info "Docker is already installed. Skipping installation."
    else
        print_info "Installing Docker..."
        # Add Docker's official GPG key
        if [ ! -f "/usr/share/keyrings/docker-archive-keyring.gpg" ]; then
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        fi

        # Set up the stable repository
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

        # Install Docker Engine
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io
        print_success "Docker installed."
    fi

    # Add user to docker group
    if [ -n "$USER_NAME" ]; then
        sudo usermod -aG docker "$USER_NAME"
        print_info "User $USER_NAME added to the docker group. You will need to log out and back in for this to take effect."
    fi

    if command -v docker-compose &> /dev/null; then
        print_info "Docker Compose is already installed. Skipping installation."
    else
        print_info "Installing Docker Compose..."
        LATEST_COMPOSE=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep "tag_name" | cut -d\" -f4)
        sudo curl -L "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        print_success "Docker Compose installed."
    fi
}

install_acme_sh() {
    if [ "$INSTALL_ACME_SH" != "true" ]; then
        print_info "Skipping SSL certificate installation."
        return
    fi

    if [ -z "$ACME_DOMAIN" ] || [ -z "$ACME_EMAIL" ]; then
        print_warn "ACME_DOMAIN or ACME_EMAIL is not set. Skipping SSL certificate installation."
        return
    fi

    print_info "Preparing for SSL certificate installation..."
    sudo apt-get update
    sudo apt-get install -y socat curl

    # Install acme.sh as root user for easier port 80 binding
    if [ -f "/root/.acme.sh/acme.sh" ]; then
        print_info "acme.sh is already installed for root user."
    else
        print_info "Installing acme.sh for root user..."
        # We use sudo to pipe to sh, so it runs as root
        curl https://get.acme.sh | sudo sh -s email="$ACME_EMAIL"
    fi

    ACME_SH_PATH="/root/.acme.sh/acme.sh"

    print_info "Setting default CA to Let's Encrypt..."
    sudo "$ACME_SH_PATH" --set-default-ca --server letsencrypt

    print_info "Issuing SSL certificate for $ACME_DOMAIN..."
    
        # Issue cert using standalone mode. This needs to run as root.
        sudo "$ACME_SH_PATH" --issue --standalone -d "$ACME_DOMAIN" --keylength ec-256
            print_success "SSL certificate process completed for $ACME_DOMAIN."
    print_info "Your certificate is located in /root/.acme.sh/$ACME_DOMAIN/"
    print_info "You may need to copy the certs to a location accessible by your services."
}

enable_bbr() {
    if [ "$ENABLE_BBR" != "true" ]; then
        print_info "Skipping BBR configuration."
        return
    fi

    print_info "Enabling TCP BBR congestion control..."

    # Check if BBR is already enabled in sysctl.conf
    if grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf && grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        print_info "BBR settings already exist in /etc/sysctl.conf."
    else
        print_info "Adding BBR settings to /etc/sysctl.conf..."
        sudo bash -c "cat >> /etc/sysctl.conf" <<EOF

# Enable BBR Congestion Control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    fi

    print_info "Applying sysctl settings..."
    sudo sysctl -p

    # Verify that BBR is running
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        print_success "BBR is enabled and running."
    else
        print_warn "BBR may not be enabled correctly. Please check your kernel version."
        print_warn "BBR requires a Linux kernel version of 4.9 or higher."
    fi
}


# --- Run Setup ---
main() {
    load_env
    update_system
    configure_ssh
    setup_iptables
    install_fail2ban
    enable_bbr
    install_docker
    install_acme_sh

    print_info "-------------------- SETUP COMPLETE --------------------"
    print_info "It is recommended to reboot the system now."
    echo "Run: sudo reboot"
}

main
