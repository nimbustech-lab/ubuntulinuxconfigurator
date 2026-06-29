#!/bin/bash

# ============================================
#        Ubuntu Server Setup Script
#         v2.0 — SpinOps Edition
# ============================================

# ===== CHECK ROOT =====
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root or with sudo"
    exit 1
fi

# ===== HELPERS =====
print_header() {
    echo ""
    echo "============================================"
    echo "  $1"
    echo "============================================"
}
print_ok()   { echo "    [  OK  ] $1"; }
print_warn() { echo "    [ WARN ] $1"; }
print_err()  { echo "    [ FAIL ] $1"; }
print_info() { echo "    [ INFO ] $1"; }
print_skip() { echo "    [ SKIP ] $1"; }

# ===== VALIDATE IP =====
validate_ip() {
    local IP=$1
    if [[ $IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a OCTETS <<< "$IP"
        for OCTET in "${OCTETS[@]}"; do
            if [ "$OCTET" -gt 255 ]; then return 1; fi
        done
        return 0
    fi
    return 1
}

# ===== VALIDATE CIDR =====
validate_cidr() {
    local CIDR=$1
    if [[ $CIDR =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
        return 0
    fi
    return 1
}

# ===== TRACK FINAL HOSTNAME FOR ZABBIX =====
FINAL_HOSTNAME=$(hostname)


# ============================================
# SECTION 1: HOSTNAME
# ============================================
print_header "STEP 1 of 5 — Set Hostname"

CURRENT_HOSTNAME=$(hostname)
print_info "Current hostname: $CURRENT_HOSTNAME"
echo ""

read -p "    Enter new hostname (leave empty to keep '$CURRENT_HOSTNAME'): " NEW_HOSTNAME

if [ -z "$NEW_HOSTNAME" ]; then
    print_skip "Hostname unchanged: $CURRENT_HOSTNAME"
    FINAL_HOSTNAME=$CURRENT_HOSTNAME
else
    hostnamectl set-hostname "$NEW_HOSTNAME"

    # Update /etc/hosts
    if grep -q "127.0.1.1" /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
    else
        echo -e "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
    fi

    FINAL_HOSTNAME=$NEW_HOSTNAME
    print_ok "Hostname set to: $NEW_HOSTNAME"
fi


# ============================================
# SECTION 2: NETWORK (IP, GATEWAY, MTU 1400)
# ============================================
print_header "STEP 2 of 5 — Configure Network (IP, Gateway, MTU: 1400)"

echo ""
echo "    Available network interfaces:"
echo ""
printf "    %-4s %-16s %-12s %s\n" "#" "Interface" "State" "Current IP"
printf "    %-4s %-16s %-12s %s\n" "-" "---------" "-----" "----------"

# Build interface list
IFACE_LIST=()
INDEX=0
while IFS= read -r LINE; do
    IFACE=$(echo "$LINE" | awk '{print $1}' | tr -d ':')
    STATE=$(echo "$LINE" | awk '{print $2}')
    IPADDR=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}')
    [ -z "$IPADDR" ] && IPADDR="(no IP)"
    [ "$IFACE" = "lo" ] && continue
    IFACE_LIST+=("$IFACE")
    printf "    %-4s %-16s %-12s %s\n" "$INDEX" "$IFACE" "$STATE" "$IPADDR"
    INDEX=$((INDEX + 1))
done < <(ip -br link show)

echo ""

if [ ${#IFACE_LIST[@]} -eq 0 ]; then
    print_err "No network interfaces found. Skipping network configuration."
else
    read -p "    Pick interface number (or press Enter to skip): " IFACE_PICK

    if [ -z "$IFACE_PICK" ]; then
        print_skip "Network configuration skipped."
    elif ! [[ "$IFACE_PICK" =~ ^[0-9]+$ ]] || [ "$IFACE_PICK" -ge "${#IFACE_LIST[@]}" ]; then
        print_err "Invalid selection. Skipping network configuration."
    else
        NET_IFACE="${IFACE_LIST[$IFACE_PICK]}"
        print_info "Selected interface: $NET_IFACE"
        echo ""

        # IP Address with CIDR
        while true; do
            read -p "    Enter IP address with subnet (e.g. 192.168.1.10/24): " NEW_IP
            if validate_cidr "$NEW_IP"; then
                break
            else
                print_err "Invalid format. Use CIDR notation e.g. 192.168.1.10/24"
            fi
        done

        # Gateway
        while true; do
            read -p "    Enter Gateway IP (e.g. 192.168.1.1): " NEW_GW
            if validate_ip "$NEW_GW"; then
                break
            else
                print_err "Invalid IP. Try again."
            fi
        done

        # DNS
        read -p "    Enter DNS comma-separated (leave empty for 8.8.8.8,8.8.4.4): " NEW_DNS
        [ -z "$NEW_DNS" ] && NEW_DNS="8.8.8.8,8.8.4.4"

        # MTU fixed at 1400
        MTU=1400
        print_info "MTU fixed at: $MTU"

        echo ""
        print_info "Writing Netplan config..."

        NETPLAN_DIR="/etc/netplan"
        NETPLAN_FILE=$(ls $NETPLAN_DIR/*.yaml 2>/dev/null | head -1)
        [ -z "$NETPLAN_FILE" ] && NETPLAN_FILE="$NETPLAN_DIR/01-netcfg.yaml"

        # Backup existing
        if [ -f "$NETPLAN_FILE" ]; then
            cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak.$(date +%Y%m%d%H%M%S)"
            print_info "Backup saved: ${NETPLAN_FILE}.bak"
        fi

        cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${NET_IFACE}:
      addresses:
        - ${NEW_IP}
      routes:
        - to: default
          via: ${NEW_GW}
      nameservers:
        addresses: [${NEW_DNS}]
      mtu: ${MTU}
      dhcp4: false
EOF

        chmod 600 "$NETPLAN_FILE"
        netplan apply && print_ok "Network applied: $NEW_IP via $NEW_GW (MTU $MTU)" || print_err "Netplan apply failed — check $NETPLAN_FILE"
    fi
fi


# ============================================
# SECTION 3: ADD USER WITH ADMIN ROLE
# ============================================
print_header "STEP 3 of 5 — Add Admin User"

echo ""
ADD_MORE_USERS=true

while [ "$ADD_MORE_USERS" = true ]; do
    read -p "    Enter new username to create (leave empty to skip): " NEW_USER

    if [ -z "$NEW_USER" ]; then
        print_skip "User creation skipped."
        ADD_MORE_USERS=false
    else
        if id "$NEW_USER" &>/dev/null; then
            print_warn "User '$NEW_USER' already exists."
            read -p "    Add '$NEW_USER' to sudo group anyway? (y/n): " ADD_SUDO
            if [ "$ADD_SUDO" = "y" ]; then
                usermod -aG sudo "$NEW_USER"
                print_ok "User '$NEW_USER' added to sudo group."
            else
                print_skip "No changes made to '$NEW_USER'."
            fi
        else
            adduser --gecos "" "$NEW_USER"
            usermod -aG sudo "$NEW_USER"
            print_ok "User '$NEW_USER' created and added to sudo group."
            print_info "Verify with: groups $NEW_USER"
        fi

        echo ""
        read -p "    Create another user? (y/n): " CREATE_ANOTHER
        if [ "$CREATE_ANOTHER" != "y" ]; then
            ADD_MORE_USERS=false
        fi
        echo ""
    fi
done


# ============================================
# SECTION 4: INSTALL ZABBIX AGENT 2 (v6.0 LTS)
# ============================================
print_header "STEP 4 of 5 — Zabbix Agent 2 (v6.0 LTS)"

# ===== FUNCTION: CLEAN UNINSTALL ZABBIX =====
zabbix_clean_uninstall() {
    print_info "Stopping Zabbix services..."
    systemctl stop zabbix-agent  2>/dev/null || true
    systemctl stop zabbix-agent2 2>/dev/null || true
    systemctl disable zabbix-agent  2>/dev/null || true
    systemctl disable zabbix-agent2 2>/dev/null || true

    print_info "Removing Zabbix packages..."
    apt remove --purge -y \
        zabbix-agent \
        zabbix-agent2 \
        zabbix-agent2-plugin-mongodb \
        zabbix-agent2-plugin-mssql \
        zabbix-agent2-plugin-postgresql \
        zabbix-release 2>/dev/null || true

    apt autoremove -y > /dev/null 2>&1
    apt clean > /dev/null 2>&1

    print_info "Removing leftover files and configs..."
    rm -rf /etc/zabbix
    rm -rf /var/log/zabbix
    rm -rf /var/run/zabbix
    rm -rf /tmp/zabbix-release*.deb

    # Remove Zabbix repo from apt sources
    rm -f /etc/apt/sources.list.d/zabbix.list
    apt update -q > /dev/null 2>&1

    print_ok "Zabbix fully uninstalled and cleaned."
}

# ===== FUNCTION: INSTALL ZABBIX =====
zabbix_install() {
    local ZABBIX_SERVER=$1

    UBUNTU_VERSION=$(lsb_release -rs)
    UBUNTU_CODENAME=$(lsb_release -sc)
    print_info "Ubuntu: $UBUNTU_VERSION ($UBUNTU_CODENAME)"

    echo ""
    print_info "Adding Zabbix 6.0 LTS repository..."
    DEB_FILE="zabbix-release_latest_6.0+ubuntu${UBUNTU_VERSION}_all.deb"
    wget -q "https://repo.zabbix.com/zabbix/6.0/ubuntu/pool/main/z/zabbix-release/${DEB_FILE}" \
        -O /tmp/${DEB_FILE}

    if [ $? -ne 0 ]; then
        print_err "Failed to download Zabbix 6.0 repo package."
        print_info "URL tried: https://repo.zabbix.com/zabbix/6.0/ubuntu/pool/main/z/zabbix-release/${DEB_FILE}"
        print_info "Check your internet connection or Ubuntu version compatibility."
        return 1
    fi

    dpkg -i /tmp/${DEB_FILE} > /dev/null 2>&1
    apt update -q > /dev/null 2>&1

    print_info "Installing zabbix-agent2 (6.0 LTS)..."
    apt install -y zabbix-agent2 > /dev/null 2>&1
    print_ok "zabbix-agent2 (6.0 LTS) installed."

    print_info "Installing optional plugins..."
    apt install -y \
        zabbix-agent2-plugin-mongodb \
        zabbix-agent2-plugin-mssql \
        zabbix-agent2-plugin-postgresql 2>/dev/null \
        && print_ok "Plugins installed." \
        || print_warn "Some plugins unavailable for Ubuntu $UBUNTU_VERSION — skipped."

    # Configure
    CONFIG_FILE="/etc/zabbix/zabbix_agent2.conf"
    print_info "Configuring $CONFIG_FILE..."

    sed -i "s/^Server=.*/Server=${ZABBIX_SERVER}/"             "$CONFIG_FILE"
    sed -i "s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER}/" "$CONFIG_FILE"
    sed -i "s/^Hostname=.*/Hostname=${FINAL_HOSTNAME}/"        "$CONFIG_FILE"

    print_ok "Zabbix Agent 2 configured:"
    print_info "  Server       = $ZABBIX_SERVER"
    print_info "  ServerActive = $ZABBIX_SERVER"
    print_info "  Hostname     = $FINAL_HOSTNAME"

    # Enable and start
    systemctl enable zabbix-agent2 > /dev/null 2>&1
    systemctl restart zabbix-agent2

    if systemctl is-active --quiet zabbix-agent2; then
        print_ok "Zabbix Agent 2 is RUNNING and ENABLED on boot."
    else
        print_err "Zabbix Agent 2 failed to start."
        print_info "Debug: journalctl -u zabbix-agent2 --no-pager -n 20"
    fi
}

# ===== CHECK IF ZABBIX IS ALREADY INSTALLED =====
ZABBIX_INSTALLED=false
ZABBIX_CURRENT_VERSION=""

if dpkg -l zabbix-agent2 2>/dev/null | grep -q "^ii"; then
    ZABBIX_INSTALLED=true
    ZABBIX_CURRENT_VERSION=$(dpkg -l zabbix-agent2 2>/dev/null | awk '/^ii/{print $3}' | head -1)
fi

echo ""

if [ "$ZABBIX_INSTALLED" = true ]; then
    print_warn "Zabbix Agent 2 is already installed."
    print_info "Installed version : $ZABBIX_CURRENT_VERSION"

    # Show current config
    CONFIG_FILE="/etc/zabbix/zabbix_agent2.conf"
    if [ -f "$CONFIG_FILE" ]; then
        CURRENT_ZBX_SERVER=$(grep "^Server=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2)
        CURRENT_ZBX_HOST=$(grep "^Hostname=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2)
        print_info "Current Server IP : $CURRENT_ZBX_SERVER"
        print_info "Current Hostname  : $CURRENT_ZBX_HOST"
    fi

    echo ""
    echo "    What would you like to do?"
    echo "      1) Reinstall fresh (clean uninstall + reinstall Zabbix 6.0 LTS)"
    echo "      2) Keep installed — update Server IP and Hostname only"
    echo "      3) Skip — leave everything as is"
    echo ""
    read -p "    Enter choice (1/2/3): " ZABBIX_CHOICE

    case "$ZABBIX_CHOICE" in

        1)
            echo ""
            print_info "Starting clean reinstall of Zabbix Agent 2 (6.0 LTS)..."
            echo ""

            # Get new Zabbix Server IP
            while true; do
                read -p "    Enter Zabbix Server IP: " ZABBIX_SERVER
                if validate_ip "$ZABBIX_SERVER"; then
                    break
                else
                    print_err "Invalid IP address. Try again."
                fi
            done

            echo ""
            zabbix_clean_uninstall
            echo ""
            zabbix_install "$ZABBIX_SERVER"
            ;;

        2)
            echo ""
            # Get new Zabbix Server IP
            while true; do
                read -p "    Enter new Zabbix Server IP: " ZABBIX_SERVER
                if validate_ip "$ZABBIX_SERVER"; then
                    break
                else
                    print_err "Invalid IP address. Try again."
                fi
            done

            CONFIG_FILE="/etc/zabbix/zabbix_agent2.conf"
            if [ -f "$CONFIG_FILE" ]; then
                sed -i "s/^Server=.*/Server=${ZABBIX_SERVER}/"             "$CONFIG_FILE"
                sed -i "s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER}/" "$CONFIG_FILE"
                sed -i "s/^Hostname=.*/Hostname=${FINAL_HOSTNAME}/"        "$CONFIG_FILE"
                print_ok "Config updated:"
                print_info "  Server       = $ZABBIX_SERVER"
                print_info "  ServerActive = $ZABBIX_SERVER"
                print_info "  Hostname     = $FINAL_HOSTNAME"
                systemctl restart zabbix-agent2
                print_ok "Zabbix Agent 2 restarted with new config."
            else
                print_err "Config file not found at $CONFIG_FILE"
            fi
            ;;

        3)
            print_skip "Zabbix left unchanged."
            ;;

        *)
            print_warn "Invalid choice. Skipping Zabbix configuration."
            ;;
    esac

else
    # Fresh install — not installed yet
    print_info "Zabbix Agent 2 is not installed. Proceeding with fresh install..."
    echo ""

    while true; do
        read -p "    Enter Zabbix Server IP: " ZABBIX_SERVER
        if validate_ip "$ZABBIX_SERVER"; then
            break
        else
            print_err "Invalid IP address. Try again."
        fi
    done

    echo ""
    zabbix_install "$ZABBIX_SERVER"
fi


# ============================================
# SECTION 5: CHECK SSH PORT (60022)
# ============================================
print_header "STEP 5 of 5 — SSH Port Check (Expected: 60022)"

SSH_CONFIG="/etc/ssh/sshd_config"
EXPECTED_PORT=60022

echo ""

if [ ! -f "$SSH_CONFIG" ]; then
    print_err "SSH config not found at $SSH_CONFIG"
else
    CURRENT_SSH_PORT=$(grep -E "^Port " "$SSH_CONFIG" | awk '{print $2}' | head -1)
    [ -z "$CURRENT_SSH_PORT" ] && CURRENT_SSH_PORT=22

    print_info "Current SSH port: $CURRENT_SSH_PORT"
    print_info "Expected SSH port: $EXPECTED_PORT"
    echo ""

    if [ "$CURRENT_SSH_PORT" -eq "$EXPECTED_PORT" ]; then
        print_ok "SSH is already on port $EXPECTED_PORT."
    else
        print_warn "SSH port is $CURRENT_SSH_PORT — expected $EXPECTED_PORT."
        echo ""
        read -p "    Change SSH port to $EXPECTED_PORT now? (y/n): " CHANGE_SSH

        if [ "$CHANGE_SSH" = "y" ]; then
            cp "$SSH_CONFIG" "${SSH_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
            print_info "Backup saved: ${SSH_CONFIG}.bak"

            if grep -qE "^#?Port " "$SSH_CONFIG"; then
                sed -i "s/^#\?Port .*/Port $EXPECTED_PORT/" "$SSH_CONFIG"
            else
                echo "Port $EXPECTED_PORT" >> "$SSH_CONFIG"
            fi

            # Update UFW if active
            if command -v ufw > /dev/null 2>&1 && ufw status | grep -q "Status: active"; then
                ufw allow ${EXPECTED_PORT}/tcp > /dev/null 2>&1
                print_ok "UFW: Allowed new SSH port $EXPECTED_PORT"

                read -p "    Remove old SSH port $CURRENT_SSH_PORT from UFW? (y/n): " REMOVE_OLD
                if [ "$REMOVE_OLD" = "y" ]; then
                    ufw delete allow ${CURRENT_SSH_PORT}/tcp > /dev/null 2>&1
                    print_ok "UFW: Removed old port $CURRENT_SSH_PORT"
                fi
            fi

            print_info "Regenerating SSH host keys..."
            ssh-keygen -A \
                && print_ok "SSH host keys regenerated." \
                || print_err "ssh-keygen -A failed. Check manually."

            systemctl restart sshd \
                && print_ok "SSH restarted on port $EXPECTED_PORT." \
                || print_err "SSH restart failed. Check: journalctl -u sshd"

            echo ""
            print_warn "IMPORTANT: Use port $EXPECTED_PORT for future SSH connections!"
            print_info "  Example: ssh -p $EXPECTED_PORT $(whoami)@$(hostname -I | awk '{print $1}')"

        else
            print_skip "SSH port unchanged."
        fi
    fi

    # UFW port summary
    echo ""
    echo "    --- UFW Firewall Port Status ---"
    echo ""

    if command -v ufw > /dev/null 2>&1; then
        print_info "UFW: $(ufw status | head -1)"
        echo ""

        FINAL_SSH_PORT=$(grep -E "^Port " "$SSH_CONFIG" | awk '{print $2}' | head -1)
        [ -z "$FINAL_SSH_PORT" ] && FINAL_SSH_PORT=22

        declare -A PORT_LABELS
        PORT_LABELS["$FINAL_SSH_PORT"]="SSH"
        PORT_LABELS["10050"]="Zabbix Passive"
        PORT_LABELS["10051"]="Zabbix Active"

        for PORT in "$FINAL_SSH_PORT" "10050" "10051"; do
            LABEL="${PORT_LABELS[$PORT]}"
            if ufw status | grep -qE "^${PORT}[/ ].*ALLOW"; then
                print_ok "$LABEL (port $PORT) — ALLOWED"
            else
                print_warn "$LABEL (port $PORT) — NOT in UFW rules"
                read -p "    Allow $LABEL port $PORT in UFW now? (y/n): " ALLOW_PORT
                if [ "$ALLOW_PORT" = "y" ]; then
                    ufw allow ${PORT}/tcp > /dev/null 2>&1
                    print_ok "$LABEL port $PORT allowed."
                fi
            fi
        done
    else
        print_warn "UFW is not installed. Install with: apt install -y ufw"
    fi
fi


# ============================================
# FINAL SUMMARY
# ============================================
print_header "ALL STEPS COMPLETE — Final Summary"

FINAL_SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
[ -z "$FINAL_SSH_PORT" ] && FINAL_SSH_PORT=22

ZABBIX_STATUS="Not installed"
if systemctl list-units --type=service 2>/dev/null | grep -q "zabbix-agent2"; then
    if systemctl is-active --quiet zabbix-agent2; then
        ZABBIX_STATUS="Running  (zabbix-agent2)"
    else
        ZABBIX_STATUS="Installed but NOT running"
    fi
fi

echo ""
printf "    %-18s %s\n" "Hostname:"   "$(hostname)"
printf "    %-18s %s\n" "IP Address:" "$(ip -br addr show 2>/dev/null | awk '$1!="lo"{print $3}' | head -1)"
printf "    %-18s %s\n" "Gateway:"    "$(ip route | awk '/default/{print $3}' | head -1)"
printf "    %-18s %s\n" "MTU:"        "1400"
printf "    %-18s %s\n" "Sudo Users:" "$(getent group sudo | cut -d: -f4)"
printf "    %-18s %s\n" "Zabbix:"     "$ZABBIX_STATUS"
printf "    %-18s %s\n" "SSH Port:"   "$FINAL_SSH_PORT"
printf "    %-18s %s\n" "UFW:"        "$(ufw status 2>/dev/null | awk 'NR==1{print $2}')"
echo ""
echo "============================================"
echo ""