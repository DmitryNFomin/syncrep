#!/usr/bin/env bash
# hetzner_destroy.sh — delete dmitry1, dmitry2, and the private network
#
# Reads infra/hetzner.env to know which network to delete, then prompts
# for confirmation before making any destructive API calls.
#
# Usage:
#   bash infra/hetzner_destroy.sh

set -euo pipefail

# ── Locate dirs ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/hetzner.env"
CONF_FILE="$SCRIPT_DIR/hetzner.conf"

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
error() { echo -e "${RED}[!] ERROR:${NC} $*" >&2; exit 1; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }

# ── Load env ──────────────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
    error "infra/hetzner.env not found — nothing to destroy.
  (hetzner_create.sh writes this file when it provisions servers.)"
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# Load HCLOUD_TOKEN from hetzner.conf if present
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

[[ -n "${HCLOUD_TOKEN:-}" ]] \
    || error "HCLOUD_TOKEN is not set.  Ensure infra/hetzner.conf contains it."

export HCLOUD_TOKEN

NETWORK_NAME="${NETWORK_NAME:-syncrep-net}"

# ── Confirmation prompt ───────────────────────────────────────────────────────
echo ""
warn "This will PERMANENTLY DELETE the following Hetzner Cloud resources:"
echo ""
echo "  Servers  : dmitry1, dmitry2"
echo "  Network  : $NETWORK_NAME"
echo ""
warn "All data on those servers will be lost.  This cannot be undone."
echo ""
printf "Destroy dmitry1, dmitry2 and private network %s? [y/N] " "$NETWORK_NAME"
read -r CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted — nothing was deleted."
    exit 0
fi

echo ""

# ── Delete servers ────────────────────────────────────────────────────────────
info "Deleting server: dmitry1 ..."
if hcloud server describe dmitry1 >/dev/null 2>&1; then
    hcloud server delete dmitry1
    info "dmitry1 deleted"
else
    warn "Server 'dmitry1' not found — skipping"
fi

info "Deleting server: dmitry2 ..."
if hcloud server describe dmitry2 >/dev/null 2>&1; then
    hcloud server delete dmitry2
    info "dmitry2 deleted"
else
    warn "Server 'dmitry2' not found — skipping"
fi

# Brief pause so that server-network interface detachments propagate before
# we attempt to delete the network.  Hetzner rejects network deletion while
# servers are still attached.
info "Waiting for server deletions to propagate ..."
sleep 8

# ── Delete network ────────────────────────────────────────────────────────────
info "Deleting network: $NETWORK_NAME ..."
if hcloud network describe "$NETWORK_NAME" >/dev/null 2>&1; then
    hcloud network delete "$NETWORK_NAME"
    info "Network '$NETWORK_NAME' deleted"
else
    warn "Network '$NETWORK_NAME' not found — skipping"
fi

# ── Clean up local state ──────────────────────────────────────────────────────
rm -f "$ENV_FILE"
info "infra/hetzner.env removed"

echo ""
echo -e "${BOLD}${GREEN}Destroyed.${NC}"
echo ""
echo "The following local files were NOT removed (review and delete if needed):"
echo "  infra/hetzner.conf   — contains your API token"
echo "  syncrep.conf         — contains IP addresses that are now invalid"
echo ""
