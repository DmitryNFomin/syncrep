#!/usr/bin/env bash
# hetzner_create.sh — provision two Hetzner Cloud VMs for syncrep benchmarks
#
# Creates:
#   dmitry1  — primary PostgreSQL node
#   dmitry2  — synchronous replica node
#   private network (10.0.0.0/16) with subnet 10.0.1.0/24
#
# Writes infra/hetzner.env with connection details for subsequent scripts.
#
# Prerequisites:
#   - hcloud CLI installed and available on PATH
#   - infra/hetzner.conf filled in (copy from hetzner.conf.example)
#
# Usage:
#   bash infra/hetzner_create.sh

set -euo pipefail

# ── Locate the repo root (parent of infra/) ───────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONF="$SCRIPT_DIR/hetzner.conf"

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
step()  { echo -e "\n${BOLD}${CYAN}==> $*${NC}"; }
error() { echo -e "${RED}[!] ERROR:${NC} $*" >&2; exit 1; }

# ── Load config ───────────────────────────────────────────────────────────────
step "Loading configuration"

if [[ ! -f "$CONF" ]]; then
    error "infra/hetzner.conf not found.
  Copy the example and fill in your values:
    cp infra/hetzner.conf.example infra/hetzner.conf
    \$EDITOR infra/hetzner.conf"
fi

# shellcheck source=/dev/null
source "$CONF"

# ── Validate required fields ──────────────────────────────────────────────────
[[ -n "${HCLOUD_TOKEN:-}" ]] \
    || error "HCLOUD_TOKEN is not set in infra/hetzner.conf"
[[ -n "${SSH_KEY_NAME:-}" ]] \
    || error "SSH_KEY_NAME is not set in infra/hetzner.conf"

# Apply defaults for optional fields
SERVER_TYPE="${SERVER_TYPE:-cx33}"
# Support both old DATACENTER and new LOCATION config keys
if [[ -z "${LOCATION:-}" && -n "${DATACENTER:-}" ]]; then
    # Map datacenter name to location (e.g. fsn1-dc14 → fsn1)
    LOCATION="${DATACENTER%%-dc*}"
fi
LOCATION="${LOCATION:-nbg1}"
IMAGE="${IMAGE:-ubuntu-24.04}"
PGVER="${PGVER:-18}"
PGPASSWORD="${PGPASSWORD:-benchpass}"
REPLICATOR_PASSWORD="${REPLICATOR_PASSWORD:-replpass}"
CLUSTER_NAME="${CLUSTER_NAME:-syncrep}"
NETWORK_NAME="${CLUSTER_NAME}-net"

export HCLOUD_TOKEN

info "Server type : $SERVER_TYPE"
info "Location    : $LOCATION"
info "Image       : $IMAGE"
info "PG version  : $PGVER"
info "Network     : $NETWORK_NAME (10.0.0.0/16)"

# ── Check hcloud CLI is available ─────────────────────────────────────────────
command -v hcloud >/dev/null 2>&1 \
    || error "hcloud CLI not found. Install from https://github.com/hetznercloud/cli"

# ── Create private network ────────────────────────────────────────────────────
step "Creating private network: $NETWORK_NAME"

if hcloud network describe "$NETWORK_NAME" >/dev/null 2>&1; then
    info "Network '$NETWORK_NAME' already exists — reusing"
else
    hcloud network create \
        --name "$NETWORK_NAME" \
        --ip-range 10.0.0.0/16
    info "Network '$NETWORK_NAME' created (10.0.0.0/16)"
fi

# Add subnet if not already present
if hcloud network describe "$NETWORK_NAME" -o json \
        | python3 -c "import json,sys; d=json.load(sys.stdin); \
          exit(0 if any(s['ip_range']=='10.0.1.0/24' for s in d['subnets']) else 1)" \
        2>/dev/null; then
    info "Subnet 10.0.1.0/24 already exists — reusing"
else
    hcloud network add-subnet "$NETWORK_NAME" \
        --type cloud \
        --network-zone eu-central \
        --ip-range 10.0.1.0/24
    info "Subnet 10.0.1.0/24 added (zone: eu-central)"
fi

# ── User-data snippets: set hostname at first boot ────────────────────────────
USERDATA_PRIMARY="$(cat <<'UDEOF'
#cloud-config
hostname: dmitry1
fqdn: dmitry1.local
manage_etc_hosts: true
UDEOF
)"

USERDATA_REPLICA="$(cat <<'UDEOF'
#cloud-config
hostname: dmitry2
fqdn: dmitry2.local
manage_etc_hosts: true
UDEOF
)"

# Write to temp files so we can pass --user-data-from-file
TMPDIR_UD="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_UD"' EXIT
echo "$USERDATA_PRIMARY" > "$TMPDIR_UD/ud-primary.yaml"
echo "$USERDATA_REPLICA" > "$TMPDIR_UD/ud-replica.yaml"

# ── Create servers ────────────────────────────────────────────────────────────
step "Creating server: dmitry1 (primary)"

if hcloud server describe dmitry1 >/dev/null 2>&1; then
    info "Server 'dmitry1' already exists — reusing"
else
    hcloud server create \
        --name dmitry1 \
        --type "$SERVER_TYPE" \
        --location "$LOCATION" \
        --image "$IMAGE" \
        --ssh-key "$SSH_KEY_NAME" \
        --network "$NETWORK_NAME" \
        --user-data-from-file "$TMPDIR_UD/ud-primary.yaml"
    info "Server 'dmitry1' created"
fi

# Small pause between creates to avoid rate-limit bursts
sleep 3

step "Creating server: dmitry2 (replica)"

if hcloud server describe dmitry2 >/dev/null 2>&1; then
    info "Server 'dmitry2' already exists — reusing"
else
    hcloud server create \
        --name dmitry2 \
        --type "$SERVER_TYPE" \
        --location "$LOCATION" \
        --image "$IMAGE" \
        --ssh-key "$SSH_KEY_NAME" \
        --network "$NETWORK_NAME" \
        --user-data-from-file "$TMPDIR_UD/ud-replica.yaml"
    info "Server 'dmitry2' created"
fi

# ── Retrieve IPs ──────────────────────────────────────────────────────────────
step "Retrieving IP addresses"

PRIMARY_PUBLIC_IP="$(hcloud server ip dmitry1)"
REPLICA_PUBLIC_IP="$(hcloud server ip dmitry2)"

PRIMARY_PRIVATE_IP="$(hcloud server describe dmitry1 -o json \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['private_net'][0]['ip'])")"
REPLICA_PRIVATE_IP="$(hcloud server describe dmitry2 -o json \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['private_net'][0]['ip'])")"

info "dmitry1  public=$PRIMARY_PUBLIC_IP  private=$PRIMARY_PRIVATE_IP"
info "dmitry2  public=$REPLICA_PUBLIC_IP  private=$REPLICA_PRIVATE_IP"

# ── Wait for SSH on both servers ──────────────────────────────────────────────
wait_for_ssh() {
    local host="$1"
    local label="$2"
    local deadline=$(( $(date +%s) + 120 ))

    info "Waiting for SSH on $label ($host) ..."
    while (( $(date +%s) < deadline )); do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
               -o BatchMode=yes \
               "root@$host" echo ok >/dev/null 2>&1; then
            info "SSH ready on $label"
            return 0
        fi
        sleep 5
    done
    error "Timed out waiting for SSH on $label ($host) after 120 s.
  The server may still be booting.  Try again in a moment:
    bash infra/init_cluster.sh"
}

step "Waiting for SSH availability"
wait_for_ssh "$PRIMARY_PUBLIC_IP" "dmitry1"
wait_for_ssh "$REPLICA_PUBLIC_IP" "dmitry2"

# ── Write hetzner.env ─────────────────────────────────────────────────────────
step "Writing infra/hetzner.env"

cat > "$SCRIPT_DIR/hetzner.env" << EOF
# Auto-generated by hetzner_create.sh — do not edit manually.
# Re-run hetzner_create.sh to regenerate.
PRIMARY_NAME="dmitry1"
REPLICA_NAME="dmitry2"
PRIMARY_PUBLIC_IP="$PRIMARY_PUBLIC_IP"
REPLICA_PUBLIC_IP="$REPLICA_PUBLIC_IP"
PRIMARY_PRIVATE_IP="$PRIMARY_PRIVATE_IP"
REPLICA_PRIVATE_IP="$REPLICA_PRIVATE_IP"
NETWORK_NAME="$NETWORK_NAME"
PGVER="$PGVER"
PGPASSWORD="$PGPASSWORD"
REPLICATOR_PASSWORD="$REPLICATOR_PASSWORD"
SSH_KEY_NAME="$SSH_KEY_NAME"
EOF

info "infra/hetzner.env written"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}Infrastructure provisioned successfully.${NC}"
echo ""
echo "  dmitry1 (primary)  — public: $PRIMARY_PUBLIC_IP   private: $PRIMARY_PRIVATE_IP"
echo "  dmitry2 (replica)  — public: $REPLICA_PUBLIC_IP   private: $REPLICA_PRIVATE_IP"
echo "  Private network    — $NETWORK_NAME (10.0.0.0/16)"
echo ""
echo "Next step — install PostgreSQL $PGVER + Patroni and form the cluster:"
echo ""
echo "  bash infra/init_cluster.sh"
echo ""
