#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# Global variables
EASYRSA_DIR="/etc/openvpn/easy-rsa"

# Function to check if the script is run as root
check_root_user() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: This script must be run as root."
        exit 1
    fi
    # If the check passes, we don't need to print anything, script continues.
}

# Function to detect OS version
detect_os_version() {
    if [ -f /etc/almalinux-release ]; then
        if grep -q "AlmaLinux release 8" /etc/almalinux-release; then
            echo "AlmaLinux 8 detected."
        else
            echo "Error: This script is intended for AlmaLinux 8 only. Found other AlmaLinux version."
            cat /etc/almalinux-release # Show what was found
            exit 1
        fi
    else
        echo "Error: This script is intended for AlmaLinux 8 only. /etc/almalinux-release not found."
        exit 1
    fi
}

# Function to get public IP address
get_public_ip() {
    # Order of preference: dig, wget, curl
    local ip
    ip=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null || \
         wget -qO- ifconfig.me 2>/dev/null || \
         curl -s ifconfig.me 2>/dev/null || \
         echo "YOUR_SERVER_IP")
    echo "$ip"
}

# Function to check if firewalld is active
is_firewalld_active() {
    systemctl is-active --quiet firewalld
}

# Function to install necessary dependencies
install_dependencies() {
    echo "Updating system and installing dependencies..."
    dnf update -y
    dnf install -y openvpn easy-rsa bind-utils coreutils
    echo "Dependencies installed successfully."
}

# Function to set up EasyRSA
setup_easyrsa() {
    echo "Setting up Easy-RSA..."
    # EASYRSA_DIR is now global
    local current_dir # To store current directory

    current_dir=$(pwd) # Save current directory

    if [ -d "$EASYRSA_DIR" ]; then
        # Check if PKI is initialized, if so, maybe skip entirely or just inform.
        if [ -f "$EASYRSA_DIR/pki/ca.crt" ]; then
             echo "Easy-RSA directory and PKI already exist. Skipping setup."
             return
        elif [ -d "$EASYRSA_DIR/pki" ]; then
             echo "Easy-RSA directory exists, and PKI seems initialized (pki dir found). Assuming setup is fine or will be handled by CA generation."
             # It's possible init-pki was run but no CA yet.
        else
            echo "Easy-RSA directory $EASYRSA_DIR already exists but PKI not fully initialized. Will attempt to continue."
        fi
    else
        mkdir -p "$EASYRSA_DIR"
        echo "Created directory $EASYRSA_DIR"
    fi
    
    # Find Easy-RSA scripts directory
    # Common locations for Easy-RSA 3.x scripts
    local easyrsa_scripts_path
    easyrsa_scripts_path=$(find /usr/share/easy-rsa -maxdepth 1 -type d -name '3' -o -name '3.*' | head -n 1)

    if [ -z "$easyrsa_scripts_path" ] || [ ! -d "$easyrsa_scripts_path" ]; then
        echo "Error: Could not find Easy-RSA 3.x scripts directory in /usr/share/easy-rsa."
        echo "Please ensure Easy-RSA is correctly installed."
        # Try to find easyrsa executable to give a hint if it's elsewhere
        local easyrsa_exe
        easyrsa_exe=$(command -v easyrsa)
        if [ -n "$easyrsa_exe" ]; then
            echo "Found 'easyrsa' executable at $easyrsa_exe, but its support files are not in the expected /usr/share/easy-rsa location."
            # If easyrsa is a script itself, its parent dir might be the scripts path
            local possible_path
            possible_path=$(dirname "$(realpath "$easyrsa_exe")")
            # check if this possible_path contains easyrsa-vars.example or other key files
            if [ -f "$possible_path/easyrsa-vars.example" ]; then
                 echo "A possible EasyRSA script location might be $possible_path"
            fi
        fi
        cd "$current_dir" # Return to original directory
        return 1 # Indicate failure
    fi

    echo "Found Easy-RSA scripts at: $easyrsa_scripts_path"
    echo "Copying Easy-RSA scripts to $EASYRSA_DIR..."
    # Copy contents if the directory is not already populated from a previous run
    if [ -z "$(ls -A "$EASYRSA_DIR")" ]; then # Only copy if EASYRSA_DIR is empty
      cp -r "$easyrsa_scripts_path"/* "$EASYRSA_DIR/"
    else
      echo "$EASYRSA_DIR is not empty. Assuming files are already in place or proceed with caution."
      # We might still want to ensure core files like 'easyrsa' script are there
      if [ ! -f "$EASYRSA_DIR/easyrsa" ]; then
        echo "Core 'easyrsa' script not found in $EASYRSA_DIR. Copying files..."
        cp -r "$easyrsa_scripts_path"/* "$EASYRSA_DIR/"
      fi
    fi


    cd "$EASYRSA_DIR" || { echo "Failed to cd into $EASYRSA_DIR"; cd "$current_dir"; return 1; }

    if [ ! -d "pki" ]; then # Only run init-pki if pki directory doesn't exist
        echo "Initializing PKI..."
        ./easyrsa init-pki
    else
        echo "PKI directory already exists. Skipping init-pki."
    fi

    echo "Easy-RSA setup complete."
    cd "$current_dir" # Return to original directory
}

# Function to generate Certificate Authority (CA)
generate_ca() {
    echo "Generating Certificate Authority (CA)..."
    cd "$EASYRSA_DIR" || { echo "Failed to cd into $EASYRSA_DIR"; return 1; }
    # Check if CA already exists
    if [ -f "pki/ca.crt" ]; then
        echo "CA certificate already exists. Skipping generation."
        return
    fi
    read -rp "Enter Common Name for CA (e.g., MyOpenVPNCA): " ca_cn
    export EASYRSA_REQ_CN="$ca_cn"
    ./easyrsa build-ca nopass
    echo "CA generation complete."
}

# Function to generate server certificate
generate_server_cert() {
    echo "Generating server certificate and key..."
    cd "$EASYRSA_DIR" || { echo "Failed to cd into $EASYRSA_DIR"; return 1; }
    # Check if server certificate already exists
    if [ -f "pki/issued/server.crt" ]; then
        echo "Server certificate already exists. Skipping generation."
        return
    fi
    read -rp "Enter Common Name for Server Certificate (e.g., server): " server_cn
    export EASYRSA_REQ_CN="$server_cn"
    ./easyrsa build-server-full server nopass # Server Common Name is 'server'
    
    echo "Generating Diffie-Hellman parameters..."
    ./easyrsa gen-dh
    # DH parameters are expected in $EASYRSA_DIR/pki/dh.pem by the server config by default
    # Optional: copy to /etc/openvpn/dh.pem if some configs expect it there.
    # cp pki/dh.pem /etc/openvpn/dh.pem 
    echo "Server certificate and DH parameters generation complete (dh.pem is in $EASYRSA_DIR/pki/)."
}

# Function to generate client certificate
# Usage: generate_client_cert <client_name>
generate_client_cert() {
    local client_name=$1
    if [ -z "$client_name" ]; then
        echo "Error: Client name not provided."
        return 1
    fi
    echo "Generating certificate for client: $client_name..."
    cd "$EASYRSA_DIR" || { echo "Failed to cd into $EASYRSA_DIR"; return 1; }
    # Check if client certificate already exists
    if [ -f "pki/issued/${client_name}.crt" ]; then
        echo "Certificate for client $client_name already exists. Skipping generation."
        return 0 # Not an error, just skip
    fi
    export EASYRSA_REQ_CN="$client_name"
    ./easyrsa build-client-full "$client_name" nopass
    echo "Client certificate for $client_name generated successfully."
}

# Function to generate server configuration
generate_server_config() {
    echo "Generating OpenVPN server configuration..."
    local server_conf="/etc/openvpn/server.conf"

    if [ -f "$server_conf" ]; then
        echo "Server configuration file $server_conf already exists. Skipping generation."
        return
    fi

    # Attempt to get the public IP address
    local public_ip
    public_ip=$(get_public_ip)

    cat > "$server_conf" <<EOF
port 1194
proto udp
dev tun
ca ${EASYRSA_DIR}/pki/ca.crt
cert ${EASYRSA_DIR}/pki/issued/server.crt
key ${EASYRSA_DIR}/pki/private/server.key
dh ${EASYRSA_DIR}/pki/dh.pem
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"    # Google DNS
push "dhcp-option DNS 1.1.1.1"    # Cloudflare DNS
keepalive 10 120
cipher AES-256-CBC
auth SHA256
user nobody
group nobody # For AlmaLinux
persist-key
persist-tun
status /var/log/openvpn/openvpn-status.log
log-append /var/log/openvpn/openvpn.log # Ensure this path is writable by 'nobody'
verb 3
explicit-exit-notify 1
remote-cert-tls client
# Verify client EKU (optional, but good practice)
# remote-cert-eku "TLS Web Client Authentication"

# CRL: Uncomment and run ./easyrsa gen-crl after revoking a cert
# crl-verify /etc/openvpn/crl.pem

# Security hardening: uncomment one of the following
# tls-auth ${EASYRSA_DIR}/pki/ta.key 0 # Bidirectional, requires key-direction 1 on client
# tls-crypt ${EASYRSA_DIR}/pki/ta.key   # Unidirectional, simpler for clients (no key-direction needed)
EOF
    # Create log directory if it doesn't exist
    mkdir -p /var/log/openvpn
    # chown nobody:nobody /var/log/openvpn # If OpenVPN runs as nobody and needs to write logs. Usually, it starts as root.

    # Ensure dh.pem is also available at /etc/openvpn/ for compatibility or other tools, server.conf uses EASYRSA_DIR path.
    if [ -f "${EASYRSA_DIR}/pki/dh.pem" ]; then
        cp "${EASYRSA_DIR}/pki/dh.pem" /etc/openvpn/dh.pem
    else
        echo "Warning: dh.pem not found in ${EASYRSA_DIR}/pki/. It should be generated with server cert."
    fi
    # Generate ta.key if not present (for tls-auth or tls-crypt)
    if [ ! -f "${EASYRSA_DIR}/pki/ta.key" ]; then
        echo "Generating ta.key for tls-auth/tls-crypt..."
        openvpn --genkey --secret "${EASYRSA_DIR}/pki/ta.key"
        echo "ta.key generated in ${EASYRSA_DIR}/pki/"
    fi

    echo "OpenVPN server configuration generated at $server_conf"
    echo "Note: You need to enable IP forwarding and configure firewall rules."
    echo "  sysctl -w net.ipv4.ip_forward=1"
    echo "  To make it persistent, ensure 'net.ipv4.ip_forward = 1' is in /etc/sysctl.d/99-openvpn-forward.conf or similar."
    
    if is_firewalld_active; then
        echo "Firewall (firewalld) instructions:"
        echo "  sudo firewall-cmd --permanent --add-service=openvpn"
        echo "  sudo firewall-cmd --permanent --add-masquerade"
        echo "  sudo firewall-cmd --reload"
    else
        echo "Firewalld is not active. Please configure your firewall manually if needed (e.g., allow UDP port 1194 and enable NAT/masquerade)."
    fi
    echo "Consider uncommenting crl-verify and tls-auth/tls-crypt lines in $server_conf for enhanced security."
}

# Function to generate client configuration template
generate_client_config_template() {
    echo "Generating client configuration template..."
    # Attempt to get the public IP address
    local public_ip
    public_ip=$(get_public_ip)

    # Create a directory to store client configs if it doesn't exist
    mkdir -p /etc/openvpn/client_configs

    local template_file="/etc/openvpn/client_configs/base.conf"

    if [ -f "$template_file" ]; then
        echo "Client configuration template $template_file already exists. Skipping generation."
        return
    fi

    cat > "$template_file" <<EOF
client
dev tun
proto udp
remote $public_ip 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
auth SHA256
verb 3
# mute-replay-warnings
# The following lines are placeholders and will be replaced by generate_client_file()
# <ca>
# -----BEGIN CERTIFICATE-----
# CA_CERT_CONTENT
# -----END CERTIFICATE-----
# </ca>
# <cert>
# -----BEGIN CERTIFICATE-----
# CLIENT_CERT_CONTENT
# -----END CERTIFICATE-----
# </cert>
# <key>
# -----BEGIN PRIVATE KEY-----
# CLIENT_KEY_CONTENT
# -----END PRIVATE KEY-----
# </key>
# Consider adding a tls-auth key for added security (requires server-side setup):
# key-direction 1
# <tls-auth>
# -----BEGIN OpenVPN Static key V1-----
# TLS_AUTH_KEY_CONTENT
# -----END OpenVPN Static key V1-----
# </tls-auth>
#
# For tls-crypt (server uses tls-crypt ${EASYRSA_DIR}/pki/ta.key):
# <tls-crypt>
# -----BEGIN OpenVPN Static key V1-----
# PASTE_TA_KEY_CONTENT_HERE
# -----END OpenVPN Static key V1-----
# </tls-crypt>
EOF
    echo "Client configuration template generated at $template_file"
    echo "If using tls-crypt on the server, you will need to manually paste the content of ${EASYRSA_DIR}/pki/ta.key into the client's <tls-crypt> block."
}

# Function to generate client .ovpn file
# Usage: generate_client_file <client_name>
generate_client_file() {
    local client_name=$1
    if [ -z "$client_name" ]; then
        echo "Error: Client name not provided for file generation."
        return 1
    fi

    echo "Generating .ovpn file for client: $client_name..."

    # Ensure client certificate exists, generate if not
    generate_client_cert "$client_name" # Uses global EASYRSA_DIR
    # Check exit status of generate_client_cert
    if [ $? -ne 0 ] && [ ! -f "${EASYRSA_DIR}/pki/issued/${client_name}.crt" ]; then
        echo "Error: Failed to generate or find certificate for client $client_name. Aborting .ovpn file generation."
        return 1
    fi


    local base_template="/etc/openvpn/client_configs/base.conf"
    local client_ovpn_file="/root/${client_name}.ovpn" # Output file location

    if [ ! -f "$base_template" ]; then
        echo "Error: Client config template $base_template not found. Please generate it first."
        return 1
    fi

    # Paths to certificates and key
    local ca_crt="${EASYRSA_DIR}/pki/ca.crt"
    local client_crt="${EASYRSA_DIR}/pki/issued/${client_name}.crt"
    local client_key="${EASYRSA_DIR}/pki/private/${client_name}.key"
    local ta_key_path="${EASYRSA_DIR}/pki/ta.key" # For tls-auth or tls-crypt

    if [ ! -f "$ca_crt" ] || [ ! -f "$client_crt" ] || [ ! -f "$client_key" ]; then
        echo "Error: One or more required certificate/key files are missing for client $client_name."
        echo "CA: $ca_crt, Client Cert: $client_crt, Client Key: $client_key"
        return 1
    fi

    # Read content of certs and key
    local ca_content
    ca_content=$(cat "$ca_crt")
    local client_crt_content
    client_crt_content=$(cat "$client_crt")
    local client_key_content
    client_key_content=$(cat "$client_key")

    # Create the .ovpn file by replacing placeholders
    # Using a temporary file for sed replacements to avoid issues with special characters in certs
    local temp_ovpn_file
    temp_ovpn_file=$(mktemp)

    cp "$base_template" "$temp_ovpn_file"

    # Remove placeholder blocks from the template copy
    # These sed commands delete the entire block from '# <ca>' to '# </ca>' (inclusive)
    sed -i '/^# <ca>$/,/^# <\/ca>$/d' "$temp_ovpn_file"
    sed -i '/^# <cert>$/,/^# <\/cert>$/d' "$temp_ovpn_file"
    sed -i '/^# <key>$/,/^# <\/key>$/d' "$temp_ovpn_file"
    # Also remove any stray single placeholder lines if they exist outside blocks (legacy)
    sed -i '/# CA_CERT_CONTENT/d' "$temp_ovpn_file"
    sed -i '/# CLIENT_CERT_CONTENT/d' "$temp_ovpn_file"
    sed -i '/# CLIENT_KEY_CONTENT/d' "$temp_ovpn_file"
    sed -i '/# TLS_AUTH_KEY_CONTENT/d' "$temp_ovpn_file" # For tls-auth if it was a placeholder
    sed -i '/# PASTE_TA_KEY_CONTENT_HERE/d' "$temp_ovpn_file" # For tls-crypt if it was a placeholder


    # Now append the actual certificates and key
    {
        echo "<ca>"
        echo "$ca_content"
        echo "</ca>"
        echo ""
        echo "<cert>"
        echo "$client_crt_content"
        echo "</cert>"
        echo ""
        echo "<key>"
        echo "$client_key_content"
        echo "</key>"
        echo ""
    } >> "$temp_ovpn_file"

    # If using tls-auth or tls-crypt, and ta.key exists, embed it.
    # The server.conf now generates ta.key, and client template has placeholder for tls-crypt.
    # For tls-auth, the client needs "key-direction 1" and the <tls-auth> block.
    # For tls-crypt, the client just needs the <tls-crypt> block.
    # This example will add a <tls-crypt> block if ta.key exists and server config might use it.
    # More sophisticated logic would check if server.conf actually has tls-crypt enabled.
    if [ -f "$ta_key_path" ]; then
        local ta_content
        ta_content=$(cat "$ta_key_path")
        # Remove existing tls-auth/tls-crypt placeholder blocks before appending a new one
        sed -i '/^# <tls-auth>$/,/^# <\/tls-auth>$/d' "$temp_ovpn_file"
        sed -i '/^# <tls-crypt>$/,/^# <\/tls-crypt>$/d' "$temp_ovpn_file"
        # Append new tls-crypt block
        {
            echo "<tls-crypt>"
            echo "$ta_content"
            echo "</tls-crypt>"
        } >> "$temp_ovpn_file"
        echo "Embedded tls-crypt key into client config."
    fi

    mv "$temp_ovpn_file" "$client_ovpn_file"

    # Note: If using tls-auth (bidirectional), client needs 'key-direction 1'
    # For now, assuming tls-auth is commented out or handled manually if enabled.

    echo ""
    echo "------------------------------------------------------"
    echo "Client configuration file generated: $client_ovpn_file"
    echo "Transfer this file to the client device."
    echo "Make sure the client has OpenVPN client software installed."
    echo "------------------------------------------------------"
}

# Function to start OpenVPN service
start_openvpn_service() {
    echo "Starting and enabling OpenVPN service for server configuration..."

    # Assuming the server configuration is /etc/openvpn/server.conf
    # The service name might be openvpn@server.service or openvpn-server@server.service
    # We'll try systemctl enable with the common name.
    # Debian/Ubuntu typically use openvpn-server@.service for configurations in /etc/openvpn/
    # and openvpn@.service for /etc/openvpn/client/ and /etc/openvpn/server/
    # Let's try the more modern systemd unit name if available.

    local service_name="openvpn-server@server.service"
    # On AlmaLinux 8, the service is typically openvpn-server@.service for /etc/openvpn/server/<config_name>.conf
    # Our config is /etc/openvpn/server.conf, so the unit should be openvpn-server@server.service.
    local service_name="openvpn-server@server.service"

    if ! systemctl list-unit-files --type=service | grep -qF "$service_name"; then
        echo "Warning: OpenVPN service unit '$service_name' not found. OpenVPN might not be installed correctly or service files are different."
        echo "Attempting with generic openvpn@server.service"
        service_name="openvpn@server.service" # A less common but possible fallback
         if ! systemctl list-unit-files --type=service | grep -qF "$service_name"; then
            echo "Error: Could not determine the correct OpenVPN service name. Tried openvpn-server@server.service and openvpn@server.service."
            return 1
        fi
    fi
    echo "Using service name: $service_name"

    # Enable IP forwarding
    echo "Enabling IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1
    # Make it persistent across reboots by creating a conf file in /etc/sysctl.d/
    local sysctl_conf="/etc/sysctl.d/99-openvpn-forward.conf"
    if [ ! -f "$sysctl_conf" ] || ! grep -q "^net.ipv4.ip_forward=1$" "$sysctl_conf"; then
        echo "net.ipv4.ip_forward=1" > "$sysctl_conf"
        echo "IP forwarding configured in $sysctl_conf"
        # Apply settings from this file (though -w already did for current session)
        sysctl -p "$sysctl_conf" >/dev/null
    fi

    echo "Starting OpenVPN service: $service_name"
    systemctl daemon-reload # Reload systemd manager configuration
    systemctl enable "$service_name" # Enable the service to start on boot
    systemctl restart "$service_name" # Start or restart the service
    
    echo ""
    echo "OpenVPN service $service_name status:"
    systemctl status "$service_name" --no-pager -l

    echo ""
    echo "---------------------------------------------------------------------------"
    if is_firewalld_active; then
        echo "IMPORTANT: Firewall Configuration (firewalld)"
        echo "If firewalld is active, you might need to allow the OpenVPN service and masquerading:"
        echo "  sudo firewall-cmd --permanent --add-service=openvpn"
        echo "  # This allows OpenVPN default port 1194/udp. If you changed it, adjust accordingly."
        echo "  # For example: sudo firewall-cmd --permanent --add-port=YOUR_PORT/udp"
        echo "  sudo firewall-cmd --permanent --add-masquerade"
        echo "  # This allows VPN clients to access the internet through the server."
        echo "  sudo firewall-cmd --reload"
        echo ""
        echo "Verify rules:"
        echo "  sudo firewall-cmd --list-services"
        echo "  sudo firewall-cmd --query-masquerade"
    else
        echo "Firewalld is not active. Please configure your firewall manually if needed."
        echo "Ensure that UDP port 1194 (or your custom port) is open for incoming connections,"
        echo "and that IP masquerading/NAT is enabled for the VPN subnet (e.g., 10.8.0.0/24) "
        echo "to allow clients to access the internet."
    fi
    echo "---------------------------------------------------------------------------"
}

# Function to stop OpenVPN service
stop_openvpn_service() {
    echo "Stopping OpenVPN service..."
    local service_name="openvpn-server@server.service"
    if ! systemctl list-unit-files --type=service | grep -qF "$service_name"; then
         echo "Warning: Service unit '$service_name' not found. Trying generic openvpn@server.service."
        service_name="openvpn@server.service"
        if ! systemctl list-unit-files --type=service | grep -qF "$service_name"; then
            echo "Error: Could not determine the correct OpenVPN service name to stop."
            return 1
        fi
    fi
    systemctl stop "$service_name"
    echo "OpenVPN service $service_name stopped."
    systemctl status "$service_name" --no-pager -l
}

# Function to revoke a client certificate
revoke_client_cert() {
   local client_name_to_revoke=$1
   if [ -z "$client_name_to_revoke" ]; then
       echo "Error: No client name provided for revocation."
       return 1
   fi
   echo "Revoking certificate for client: $client_name_to_revoke..."
   cd "$EASYRSA_DIR" || { echo "Failed to cd into $EASYRSA_DIR"; return 1; }

   # Ensure vars is sourced if needed by easyrsa script for specific env vars, though not usually for revoke
   # . ./vars 

   # Revoke the certificate
   # The command will ask for confirmation.
   # To automate, use --batch option if available and suitable.
   ./easyrsa revoke "$client_name_to_revoke"
   if [ $? -ne 0 ]; then
       echo "Error revoking certificate. Check EasyRSA output."
       cd - >/dev/null
       return 1
   fi

   # Generate a new Certificate Revocation List (CRL)
   echo "Generating new CRL..."
   ./easyrsa gen-crl
   if [ $? -ne 0 ]; then
       echo "Error generating CRL. Check EasyRSA output."
       cd - >/dev/null
       return 1
   fi

   # Copy CRL to OpenVPN directory (standard location)
   cp "pki/crl.pem" /etc/openvpn/crl.pem
   echo "Certificate for $client_name_to_revoke revoked."
   echo "New CRL generated and copied to /etc/openvpn/crl.pem"
   echo "Ensure your server configuration (/etc/openvpn/server.conf) has the following line uncommented or added:"
   echo "  crl-verify /etc/openvpn/crl.pem"
   echo "You must restart the OpenVPN server to apply the new CRL."
   cd - >/dev/null # Return to previous directory
}


# Function to display the main menu
main_menu() {
    while true; do
        echo ""
        echo "OpenVPN Server Setup Script (AlmaLinux 8)"
        echo "-----------------------------------------"
        echo "1. Initial Setup (Install dependencies, setup EasyRSA, CA, Server/Client templates)"
        echo "2. Generate New Client .ovpn File"
        echo "3. Start OpenVPN Service"
        echo "4. Stop OpenVPN Service"
        echo "5. Check OpenVPN Service Status"
        echo "6. Generate new Diffie-Hellman parameters"
        echo "7. Revoke a Client Certificate"
        echo "8. Exit"
        echo "-----------------------------------------"
        read -rp "Enter your choice [1-8]: " choice

        case $choice in
            1)
                echo "Starting initial setup..."
                install_dependencies
                setup_easyrsa
                generate_ca
                generate_server_cert # This also generates initial DH params
                generate_server_config # This also generates ta.key
                generate_client_config_template
                echo "Initial setup complete. You may want to start the service (option 3) and generate client files (option 2)."
                ;;
            2)
                read -rp "Enter a name for the new client (e.g., client1, phone, laptop): " client_name_input
                if [ -n "$client_name_input" ]; then
                    generate_client_file "$client_name_input"
                else
                    echo "Client name cannot be empty."
                fi
                ;;
            3)
                start_openvpn_service
                ;;
            4)
                stop_openvpn_service
                ;;
            5)
                local service_name_status="openvpn-server@server.service"
                # Check primary service name first
                if ! systemctl list-unit-files --type=service | grep -qF "$service_name_status"; then
                    service_name_status="openvpn@server.service" # Fallback check
                fi
                echo "Checking status of $service_name_status..."
                systemctl status "$service_name_status" --no-pager -l
                ;;
            6) # Generate new DH params
                echo "Generating new Diffie-Hellman parameters..."
                cd "$EASYRSA_DIR" || { echo "Failed to cd into $EASYRSA_DIR"; continue; } # continue will go to next loop iteration
                ./easyrsa gen-dh
                # The server config points to $EASYRSA_DIR/pki/dh.pem
                # Copy to /etc/openvpn/dh.pem as well for consistency or other tools
                cp "pki/dh.pem" /etc/openvpn/dh.pem
                echo "New DH parameters generated in ${EASYRSA_DIR}/pki/dh.pem and copied to /etc/openvpn/dh.pem."
                echo "Please restart the OpenVPN service for changes to take effect."
                cd - >/dev/null # Return to previous directory
                ;;
            7) # Revoke Client Certificate
                read -rp "Enter the Common Name of the client certificate to revoke: " client_to_revoke
                if [ -n "$client_to_revoke" ]; then
                    revoke_client_cert "$client_to_revoke"
                else
                    echo "Client name cannot be empty."
                fi
                ;;
            8)
                echo "Exiting."
                exit 0
                ;;
            *)
                echo "Invalid choice. Please enter a number between 1 and 8."
                ;;
        esac
        read -rp "Press Enter to return to the menu..."
    done
}

# Main function
main() {
    check_root_user
    detect_os_version
    # The rest of the setup is handled by the menu options.
    main_menu
}

# Call main function
main
