#!/bin/bash

# ============================================
#     Zabbix Agent 2 — Version Picker
#         v1.0 — SpinOps Edition
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
            [ "$OCTET" -gt 255 ] && return 1
        done
        return 0
    fi
    return 1
}

# ============================================
# BANNER
# ============================================
clear
echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║     Zabbix Agent 2 — Version Installer   ║"
echo "  ║           SpinOps Edition v1.0           ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# ============================================
# DETECT SYSTEM
# ============================================
print_header "System Detection"

UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null)
UBUNTU_CODENAME=$(lsb_release -sc 2>/dev/null)
SYSTEM_HOSTNAME=$(hostname)
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)

print_info "OS           : Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME)"
print_info "Hostname     : $SYSTEM_HOSTNAME"
print_info "Architecture : $ARCH"

# ============================================
# CHECK EXISTING ZABBIX INSTALLATION
# ============================================
print_header "Checking Existing Zabbix Installation"

ZABBIX_INSTALLED=false
INSTALLED_VERSION=""
INSTALLED_SERVER=""
INSTALLED_HOSTNAME=""

if dpkg -l zabbix-agent2 2>/dev/null | grep -q "^ii"; then
    ZABBIX_INSTALLED=true
    INSTALLED_VERSION=$(dpkg -l zabbix-agent2 2>/dev/null | awk '/^ii/{print $3}' | head -1)
    CONFIG_FILE="/etc/zabbix/zabbix_agent2.conf"
    if [ -f "$CONFIG_FILE" ]; then
        INSTALLED_SERVER=$(grep "^Server=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | head -1)
        INSTALLED_HOSTNAME=$(grep "^Hostname=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | head -1)
    fi

    echo ""
    print_warn "Zabbix Agent 2 is already installed!"
    print_info "Installed Version : $INSTALLED_VERSION"
    print_info "Zabbix Server IP  : ${INSTALLED_SERVER:-not set}"
    print_info "Agent Hostname    : ${INSTALLED_HOSTNAME:-not set}"
    print_info "Service Status    : $(systemctl is-active zabbix-agent2 2>/dev/null)"
    echo ""
    read -p "    Proceed with reinstall? (yes/no): " REINSTALL
    if [ "$REINSTALL" != "yes" ]; then
        print_skip "Installation cancelled. Existing Zabbix Agent 2 unchanged."
        echo ""
        exit 0
    fi
else
    print_ok "No existing Zabbix Agent 2 installation found. Proceeding with fresh install."
fi

# ============================================
# FETCH AVAILABLE VERSIONS FROM ZABBIX REPO
# ============================================
print_header "Fetching Available Zabbix Versions"

echo ""
print_info "Checking Zabbix repository for available versions..."
echo ""

# Install wget if not present
if ! command -v wget > /dev/null 2>&1; then
    apt-get install -y wget > /dev/null 2>&1
fi

# Known supported Zabbix LTS and standard versions
# We probe each one against the Ubuntu version to see if a repo package exists
CANDIDATE_VERSIONS=("7.2" "7.0" "6.4" "6.2" "6.0" "5.4" "5.2" "5.0")

AVAILABLE_VERSIONS=()
AVAILABLE_URLS=()

echo "    Probing Zabbix repository for Ubuntu $UBUNTU_VERSION..."
echo ""

for VER in "${CANDIDATE_VERSIONS[@]}"; do
    URL="https://repo.zabbix.com/zabbix/${VER}/ubuntu/pool/main/z/zabbix-release/"
    HTTP_CODE=$(wget --spider --server-response "$URL" 2>&1 | grep "HTTP/" | tail -1 | awk '{print $2}')

    # Also check if the specific deb for this Ubuntu version exists
    DEB_URL="https://repo.zabbix.com/zabbix/${VER}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${VER}+ubuntu${UBUNTU_VERSION}_all.deb"
    DEB_CODE=$(wget --spider --server-response "$DEB_URL" 2>&1 | grep "HTTP/" | tail -1 | awk '{print $2}')

    if [ "$DEB_CODE" = "200" ]; then
        # Mark LTS versions
        LTS_TAG=""
        if [ "$VER" = "6.0" ] || [ "$VER" = "7.0" ]; then
            LTS_TAG=" [LTS]"
        fi
        AVAILABLE_VERSIONS+=("$VER")
        AVAILABLE_URLS+=("$DEB_URL")
        printf "    %-4s  Zabbix %-6s%s — Available for Ubuntu %s\n" \
            "[$(( ${#AVAILABLE_VERSIONS[@]} - 1 ))]" "$VER" "$LTS_TAG" "$UBUNTU_VERSION"
    else
        printf "    %-4s  Zabbix %-6s — Not available for Ubuntu %s\n" \
            " -- " "$VER" "$UBUNTU_VERSION"
    fi
done

echo ""

if [ ${#AVAILABLE_VERSIONS[@]} -eq 0 ]; then
    print_err "No Zabbix versions found for Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME)."
    print_info "Check https://repo.zabbix.com for manual installation."
    exit 1
fi

# ============================================
# VERSION SELECTION
# ============================================
print_header "Select Zabbix Version to Install"

echo ""
while true; do
    read -p "    Enter version number (0-$(( ${#AVAILABLE_VERSIONS[@]} - 1 ))): " VERSION_PICK

    if [[ "$VERSION_PICK" =~ ^[0-9]+$ ]] && [ "$VERSION_PICK" -lt "${#AVAILABLE_VERSIONS[@]}" ]; then
        SELECTED_VERSION="${AVAILABLE_VERSIONS[$VERSION_PICK]}"
        SELECTED_URL="${AVAILABLE_URLS[$VERSION_PICK]}"
        break
    else
        print_err "Invalid selection. Please enter a number between 0 and $(( ${#AVAILABLE_VERSIONS[@]} - 1 ))."
    fi
done

echo ""
print_ok "Selected: Zabbix Agent 2 v${SELECTED_VERSION}"

# Mark if LTS
if [ "$SELECTED_VERSION" = "6.0" ] || [ "$SELECTED_VERSION" = "7.0" ]; then
    print_info "This is a Long Term Support (LTS) release."
fi

# ============================================
# ZABBIX SERVER IP
# ============================================
print_header "Zabbix Server Configuration"

echo ""
while true; do
    read -p "    Enter Zabbix Server IP: " ZABBIX_SERVER
    if validate_ip "$ZABBIX_SERVER"; then
        break
    else
        print_err "Invalid IP address format. Try again."
    fi
done

# Agent Hostname
echo ""
print_info "Agent Hostname will follow system hostname: $SYSTEM_HOSTNAME"
read -p "    Use a different hostname? (leave empty to use '$SYSTEM_HOSTNAME'): " CUSTOM_HOSTNAME
if [ -z "$CUSTOM_HOSTNAME" ]; then
    AGENT_HOSTNAME=$SYSTEM_HOSTNAME
else
    AGENT_HOSTNAME=$CUSTOM_HOSTNAME
fi

print_ok "Zabbix Server IP : $ZABBIX_SERVER"
print_ok "Agent Hostname   : $AGENT_HOSTNAME"

# ============================================
# CONFIRM BEFORE INSTALL
# ============================================
print_header "Confirm Installation"

echo ""
echo "    The following will be installed:"
echo ""
printf "    %-22s %s\n" "Zabbix Version:"   "$SELECTED_VERSION"
printf "    %-22s %s\n" "Ubuntu Version:"   "$UBUNTU_VERSION ($UBUNTU_CODENAME)"
printf "    %-22s %s\n" "Zabbix Server IP:" "$ZABBIX_SERVER"
printf "    %-22s %s\n" "Agent Hostname:"   "$AGENT_HOSTNAME"
if [ "$ZABBIX_INSTALLED" = true ]; then
    printf "    %-22s %s\n" "Action:" "CLEAN REINSTALL (removes v$INSTALLED_VERSION)"
else
    printf "    %-22s %s\n" "Action:" "Fresh Install"
fi
echo ""
read -p "    Proceed? (yes/no): " FINAL_CONFIRM

if [ "$FINAL_CONFIRM" != "yes" ]; then
    print_skip "Installation cancelled."
    echo ""
    exit 0
fi

# ============================================
# CLEAN UNINSTALL (if existing)
# ============================================
if [ "$ZABBIX_INSTALLED" = true ]; then
    print_header "Clean Uninstall — Removing Existing Zabbix"

    print_info "Stopping Zabbix services..."
    systemctl stop zabbix-agent  2>/dev/null || true
    systemctl stop zabbix-agent2 2>/dev/null || true
    systemctl disable zabbix-agent  2>/dev/null || true
    systemctl disable zabbix-agent2 2>/dev/null || true

    print_info "Purging Zabbix packages..."
    apt-get remove --purge -y \
        zabbix-agent \
        zabbix-agent2 \
        zabbix-agent2-plugin-mongodb \
        zabbix-agent2-plugin-mssql \
        zabbix-agent2-plugin-postgresql \
        zabbix-release 2>/dev/null || true

    apt-get autoremove -y > /dev/null 2>&1
    apt-get clean > /dev/null 2>&1

    print_info "Removing leftover files..."
    rm -rf /etc/zabbix
    rm -rf /var/log/zabbix
    rm -rf /var/run/zabbix
    rm -f  /etc/apt/sources.list.d/zabbix.list
    rm -f  /tmp/zabbix-release*.deb

    apt-get update -q > /dev/null 2>&1

    print_ok "Existing Zabbix fully removed."
fi

# ============================================
# INSTALL SELECTED VERSION
# ============================================
print_header "Installing Zabbix Agent 2 v${SELECTED_VERSION}"

# Download repo package
DEB_FILE="zabbix-release_latest_${SELECTED_VERSION}+ubuntu${UBUNTU_VERSION}_all.deb"
print_info "Downloading Zabbix ${SELECTED_VERSION} repository package..."
wget -q "$SELECTED_URL" -O /tmp/${DEB_FILE}

if [ $? -ne 0 ]; then
    print_err "Download failed. Check internet connection."
    print_info "URL: $SELECTED_URL"
    exit 1
fi

print_info "Installing repository package..."
dpkg -i /tmp/${DEB_FILE} > /dev/null 2>&1
apt-get update -q > /dev/null 2>&1

print_info "Installing zabbix-agent2..."
apt-get install -y zabbix-agent2 > /dev/null 2>&1

if ! dpkg -l zabbix-agent2 2>/dev/null | grep -q "^ii"; then
    print_err "zabbix-agent2 installation failed."
    exit 1
fi

print_ok "zabbix-agent2 v${SELECTED_VERSION} installed."

# Install optional plugins
print_info "Installing optional plugins..."
apt-get install -y \
    zabbix-agent2-plugin-mongodb \
    zabbix-agent2-plugin-mssql \
    zabbix-agent2-plugin-postgresql 2>/dev/null \
    && print_ok "Optional plugins installed." \
    || print_warn "Some plugins unavailable for Ubuntu $UBUNTU_VERSION — skipped."

# ============================================
# CONFIGURE ZABBIX AGENT 2
# ============================================
print_header "Configuring Zabbix Agent 2"

CONFIG_FILE="/etc/zabbix/zabbix_agent2.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    print_err "Config file not found at $CONFIG_FILE"
    exit 1
fi

# Backup config
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
print_info "Config backup saved."

sed -i "s/^Server=.*/Server=${ZABBIX_SERVER}/"             "$CONFIG_FILE"
sed -i "s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER}/" "$CONFIG_FILE"
sed -i "s/^Hostname=.*/Hostname=${AGENT_HOSTNAME}/"        "$CONFIG_FILE"

print_ok "Configuration applied:"
print_info "  Server       = $ZABBIX_SERVER"
print_info "  ServerActive = $ZABBIX_SERVER"
print_info "  Hostname     = $AGENT_HOSTNAME"

# ============================================
# ENABLE AND START SERVICE
# ============================================
print_header "Starting Zabbix Agent 2"

systemctl enable zabbix-agent2 > /dev/null 2>&1
systemctl restart zabbix-agent2

sleep 2

if systemctl is-active --quiet zabbix-agent2; then
    print_ok "Zabbix Agent 2 is RUNNING."
    print_ok "Zabbix Agent 2 is ENABLED on boot."
else
    print_err "Zabbix Agent 2 failed to start."
    print_info "Check logs: journalctl -u zabbix-agent2 --no-pager -n 30"
    exit 1
fi

# ============================================
# UFW — ALLOW ZABBIX PORTS
# ============================================
print_header "Firewall (UFW) — Zabbix Ports"

if command -v ufw > /dev/null 2>&1; then
    UFW_STATUS=$(ufw status | head -1 | awk '{print $2}')
    print_info "UFW Status: $UFW_STATUS"

    if [ "$UFW_STATUS" = "active" ]; then
        for PORT in "10050" "10051"; do
            if ufw status | grep -qE "^${PORT}[/ ].*ALLOW"; then
                print_ok "Port $PORT already allowed in UFW."
            else
                ufw allow ${PORT}/tcp > /dev/null 2>&1
                print_ok "Port $PORT allowed in UFW."
            fi
        done
    else
        print_skip "UFW is inactive — skipping firewall rules."
    fi
else
    print_skip "UFW not installed — skipping firewall rules."
fi

# ============================================
# FINAL SUMMARY
# ============================================
print_header "Installation Complete — Summary"

FINAL_VERSION=$(dpkg -l zabbix-agent2 2>/dev/null | awk '/^ii/{print $3}' | head -1)

echo ""
printf "    %-22s %s\n" "Zabbix Version:"    "$FINAL_VERSION"
printf "    %-22s %s\n" "Ubuntu Version:"    "$UBUNTU_VERSION ($UBUNTU_CODENAME)"
printf "    %-22s %s\n" "Zabbix Server IP:"  "$ZABBIX_SERVER"
printf "    %-22s %s\n" "Agent Hostname:"    "$AGENT_HOSTNAME"
printf "    %-22s %s\n" "Config File:"       "$CONFIG_FILE"
printf "    %-22s %s\n" "Service Status:"    "$(systemctl is-active zabbix-agent2)"
printf "    %-22s %s\n" "Enabled on Boot:"   "$(systemctl is-enabled zabbix-agent2)"
printf "    %-22s %s\n" "Zabbix Port 10050:" "$(ufw status 2>/dev/null | grep -qE '^10050' && echo 'Allowed' || echo 'Not in UFW')"
printf "    %-22s %s\n" "Zabbix Port 10051:" "$(ufw status 2>/dev/null | grep -qE '^10051' && echo 'Allowed' || echo 'Not in UFW')"
echo ""
echo "============================================"
echo ""
