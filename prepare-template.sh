#!/bin/bash
# =============================================================================
# VM Template Preparation Script
# Prepares a Linux VM for use as a clean VMware/cloud template.
# Run as a user with sudo privileges. The machine will shut down at the end.
# =============================================================================

set -euo pipefail

# --- Colours -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Colour

log()    { echo -e "${GREEN}[✔]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }
header() { echo -e "\n${BLUE}━━━ $1 ━━━${NC}"; }

# --- Root check --------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root. Use: sudo $0"
fi

echo -e "${BLUE}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║       VM Template Preparation Script         ║"
echo "  ║   This machine will shut down when complete  ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"

read -rp "  Are you sure you want to prepare this VM as a template? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { warn "Aborted by user."; exit 0; }

# =============================================================================
# STEP 1 — Install required packages
# =============================================================================
header "STEP 1 — Installing required packages"

apt-get update -qq
apt-get install -y open-vm-tools cloud-init net-tools
log "Packages installed: open-vm-tools, cloud-init, net-tools"

# =============================================================================
# STEP 2 — Enable required services
# =============================================================================
header "STEP 2 — Enabling services"

systemctl enable open-vm-tools
log "open-vm-tools enabled"

systemctl enable cloud-init
log "cloud-init enabled"

# =============================================================================
# STEP 3 — Reset machine identity
# =============================================================================
header "STEP 3 — Resetting machine identity"

# Clear machine-id (critical: prevents duplicate IDs on cloned VMs)
truncate -s 0 /etc/machine-id
log "Cleared /etc/machine-id"

# Recreate the dbus machine-id symlink
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
log "Recreated /var/lib/dbus/machine-id symlink"

# =============================================================================
# STEP 4 — Remove SSH host keys
# =============================================================================
header "STEP 4 — Removing SSH host keys"

rm -f /etc/ssh/ssh_host_*
log "SSH host keys removed (will regenerate on first boot)"

# Remove authorized_keys from all home directories
find /home -name "authorized_keys" -delete 2>/dev/null && \
    log "Removed authorized_keys from /home/*" || \
    warn "No authorized_keys found in /home (skipped)"

rm -f /root/.ssh/authorized_keys 2>/dev/null && \
    log "Removed root authorized_keys" || true

# =============================================================================
# STEP 5 — Clear shell history
# =============================================================================
header "STEP 5 — Clearing shell history"

# Current user history
history -c 2>/dev/null || true
cat /dev/null > ~/.bash_history 2>/dev/null || true

# Root history
cat /dev/null > /root/.bash_history 2>/dev/null || true

# All home directories
find /home -name ".bash_history" -exec truncate -s 0 {} \; 2>/dev/null || true
find /home -name ".zsh_history"  -exec truncate -s 0 {} \; 2>/dev/null || true

log "Shell histories cleared"

# =============================================================================
# STEP 6 — Clean apt cache & package lists
# =============================================================================
header "STEP 6 — Cleaning apt cache"

apt-get clean
rm -rf /var/lib/apt/lists/*
log "APT cache and package lists cleaned"

# =============================================================================
# STEP 7 — Clean cloud-init state
# =============================================================================
header "STEP 7 — Cleaning cloud-init state"

cloud-init clean --logs
rm -rf /var/lib/cloud/*
log "cloud-init state and logs cleaned"

# =============================================================================
# STEP 8 — Remove temporary and log files
# =============================================================================
header "STEP 8 — Removing temp files and logs"

rm -rf /tmp/*
rm -rf /var/tmp/*
log "Temporary files cleared"

rm -rf /var/log/*
log "System logs cleared"

# =============================================================================
# STEP 9 — Zero out free disk space (optional — reduces template file size)
# =============================================================================
header "STEP 9 — Zero-filling free space (reduces template size)"

read -rp "  Zero-fill free disk space? This may take a while. [y/N] " zerofill
if [[ "${zerofill,,}" == "y" ]]; then
    warn "Zero-filling — this will take some time..."
    dd if=/dev/zero of=/zerofill bs=1M 2>/dev/null || true
    rm -f /zerofill
    sync
    log "Zero-fill complete"
else
    warn "Zero-fill skipped"
fi

# =============================================================================
# DONE — Shut down
# =============================================================================
header "All steps complete — shutting down"

echo ""
log "VM is ready to be converted to a template."
warn "Shutting down in 5 seconds... (Ctrl+C to abort)"
sleep 5

shutdown now
