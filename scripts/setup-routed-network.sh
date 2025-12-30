#!/bin/bash
# OVN Routed Network Setup for MicroCloud/LXD
# Interactive setup script

set -e

# Colors
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== MicroCloud/LXD OVN Routed Network Setup ===${NC}"

# Check requirements
if ! command -v lxc &> /dev/null; then
    echo "Error: 'lxc' command not found."
    exit 1
fi

# --- Step 1: Select Project ---
echo "Fetching projects..."
PROJECT_LIST=($(lxc project list --format csv -c n))

if [ ${#PROJECT_LIST[@]} -eq 0 ]; then
    echo "No projects found. Using 'default'."
    PROJECT="default"
else
    echo "Available Projects:"
    select p in "${PROJECT_LIST[@]}"; do
        if [ -n "$p" ]; then
            PROJECT="$p"
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
fi
echo "Selected Project: $PROJECT"
echo ""

# --- Step 2: Uplink Configuration ---
echo "--- Uplink Configuration ---"
echo "Existing physical networks:"
lxc network list --project default --format csv -c n,t | grep ",physical" | cut -d, -f1 || echo "None"

read -p "Enter Uplink Network Name (existing or new) [uplink-lgsi-int]: " UPLINK
UPLINK=${UPLINK:-uplink-lgsi-int}

# Check if uplink exists
if lxc network show "$UPLINK" --project default &>/dev/null; then
    echo "Uplink '$UPLINK' exists. Using existing configuration."
    UPLINK_EXISTS=true
else
    echo "Uplink '$UPLINK' does not exist. We will create it."
    UPLINK_EXISTS=false
fi

if [ "$UPLINK_EXISTS" = "false" ]; then
    read -p "Enter Physical Interface on host (e.g., bond0, eno1) [bond0.1810]: " PHYSICAL_IFACE
    PHYSICAL_IFACE=${PHYSICAL_IFACE:-bond0.1810}

    read -p "Enter External Gateway IP (e.g., 10.180.10.254): " EXTERNAL_GATEWAY
    
    read -p "Enter External DNS (e.g., 8.8.8.8) [${EXTERNAL_GATEWAY}]: " EXTERNAL_DNS
    EXTERNAL_DNS=${EXTERNAL_DNS:-$EXTERNAL_GATEWAY}
    
    read -p "Enter OVN Router External IP (IP on uplink for OVN) [10.180.10.1]: " OVN_ROUTER_IP
    OVN_ROUTER_IP=${OVN_ROUTER_IP:-10.180.10.1}
fi

# --- Step 3: Internal Network Configuration ---
echo ""
echo "--- Internal Network Configuration ---"
read -p "Enter New Network Name [ovn-lgsi-int]: " NETWORK
NETWORK=${NETWORK:-ovn-lgsi-int}

read -p "Enter Internal Subnet (CIDR) [10.180.15.0/24]: " INTERNAL_SUBNET
INTERNAL_SUBNET=${INTERNAL_SUBNET:-10.180.15.0/24}

read -p "Enter Internal Gateway IP [10.180.15.254]: " INTERNAL_GATEWAY
INTERNAL_GATEWAY=${INTERNAL_GATEWAY:-10.180.15.254}

echo ""
echo "=== Configuration Summary ==="
echo "Project:          $PROJECT"
echo "Uplink:           $UPLINK"
if [ "$UPLINK_EXISTS" = "false" ]; then
echo "  Physical Iface: $PHYSICAL_IFACE"
echo "  Ext Gateway:    $EXTERNAL_GATEWAY"
echo "  OVN Router IP:  $OVN_ROUTER_IP"
fi
echo "Network Name:     $NETWORK"
echo "Internal Subnet:  $INTERNAL_SUBNET"
echo "Internal Gateway: $INTERNAL_GATEWAY"
echo ""

read -p "Proceed with setup? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# --- Execution ---

# 1. Create Uplink if needed
if [ "$UPLINK_EXISTS" = "false" ]; then
    echo "Detecting cluster nodes..."
    NODES=($(lxc cluster list --format csv -c n))
    
    echo "Creating uplink '$UPLINK' on nodes: ${NODES[*]}"
    for NODE in "${NODES[@]}"; do
        echo "  Targeting $NODE..."
        lxc network create "$UPLINK" --project default --type=physical --target="$NODE" parent="$PHYSICAL_IFACE" || echo "  Warning: Failed to create on $NODE (might already exist)"
    done

    echo "Finalizing uplink '$UPLINK'..."
    lxc network create "$UPLINK" --project default --type=physical \
        ipv4.ovn.ranges="${OVN_ROUTER_IP}-${OVN_ROUTER_IP}" \
        ipv4.gateway="${EXTERNAL_GATEWAY}/24" \
        dns.nameservers="$EXTERNAL_DNS"
fi

# 2. Update Uplink Routes
echo "Updating routes on uplink '$UPLINK'..."
CURRENT_ROUTES=$(lxc network get "$UPLINK" ipv4.routes --project default || echo "")
if [ -z "$CURRENT_ROUTES" ]; then
    NEW_ROUTES="$INTERNAL_SUBNET"
else
    if [[ "$CURRENT_ROUTES" != *"$INTERNAL_SUBNET"* ]]; then
        NEW_ROUTES="${CURRENT_ROUTES},${INTERNAL_SUBNET}"
    else
        NEW_ROUTES="$CURRENT_ROUTES"
    fi
fi
lxc network set "$UPLINK" ipv4.routes="$NEW_ROUTES" --project default

# 3. Configure Project Features
echo "Configuring project features for '$PROJECT'..."
lxc project set "$PROJECT" features.networks=true
lxc project set "$PROJECT" features.networks.zones=true

# 4. Create OVN Network
echo "Creating OVN routed network '$NETWORK' in project '$PROJECT'..."
if lxc network show "$NETWORK" --project "$PROJECT" &>/dev/null; then
    echo "Network '$NETWORK' already exists. Updating configuration..."
    lxc network set "$NETWORK" --project "$PROJECT" \
        network="$UPLINK" \
        ipv4.address="${INTERNAL_GATEWAY}/24" \
        ipv4.nat=false \
        ipv4.dhcp=true
else
    lxc network create "$NETWORK" \
      --project="$PROJECT" \
      --type=ovn \
      network="$UPLINK" \
      ipv4.address="${INTERNAL_GATEWAY}/24" \
      ipv4.nat=false \
      ipv4.dhcp=true
fi

echo ""
echo "=== Setup Complete ==="