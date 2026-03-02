#!/usr/bin/env bash
# setup_node.sh — bootstrap ONE node: install PG, Patroni, create directories
#
# Runs ON the remote server as root (uploaded and executed via SSH by init_cluster.sh).
#
# Usage:
#   bash setup_node.sh PGVER NODE_ROLE PRIMARY_PRIVATE_IP REPLICA_PRIVATE_IP PGPASSWORD REPLICATOR_PASSWORD
#
# Arguments:
#   $1  PGVER               PostgreSQL major version (default: 18)
#   $2  NODE_ROLE           primary | replica
#   $3  PRIMARY_PRIVATE_IP  Hetzner private IP of the primary
#   $4  REPLICA_PRIVATE_IP  Hetzner private IP of the replica
#   $5  PGPASSWORD          postgres superuser password
#   $6  REPLICATOR_PASSWORD replication user password (used later by Patroni)
#
# After this script finishes, init_cluster.sh writes /etc/patroni/patroni.yml
# and starts the patroni service.

set -euo pipefail

# ── Arguments ─────────────────────────────────────────────────────────────────
PGVER="${1:-18}"
NODE_ROLE="${2:-primary}"
PRIMARY_PRIVATE_IP="${3:?PRIMARY_PRIVATE_IP (arg 3) is required}"
REPLICA_PRIVATE_IP="${4:?REPLICA_PRIVATE_IP (arg 4) is required}"
PGPASSWORD="${5:?PGPASSWORD (arg 5) is required}"
REPLICATOR_PASSWORD="${6:?REPLICATOR_PASSWORD (arg 6) is required}"

echo "[setup_node] PGVER=$PGVER  ROLE=$NODE_ROLE"
echo "[setup_node] PRIMARY=$PRIMARY_PRIVATE_IP  REPLICA=$REPLICA_PRIVATE_IP"

# ── 1. System packages ────────────────────────────────────────────────────────
echo "[setup_node] Updating apt cache ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

echo "[setup_node] Installing base packages ..."
apt-get install -y -qq \
    curl \
    wget \
    gnupg2 \
    lsb-release \
    python3 \
    python3-pip \
    python3-psycopg2 \
    build-essential \
    libpq-dev \
    python3-dev

# ── 2. Install PostgreSQL from PGDG ──────────────────────────────────────────
echo "[setup_node] Installing PostgreSQL $PGVER from PGDG ..."

install -d /usr/share/postgresql-common/pgdg

# Import the PGDG signing key
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc

# Add the PGDG apt source
DISTRO="$(lsb_release -cs)"
cat > /etc/apt/sources.list.d/pgdg.list << SOURCEOF
deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${DISTRO}-pgdg main
SOURCEOF

apt-get update -qq
apt-get install -y "postgresql-${PGVER}"

echo "[setup_node] PostgreSQL $PGVER installed"

# ── 3. Stop and disable the default postgres service ─────────────────────────
# Patroni manages PostgreSQL startup; the stock systemd unit must not run.
echo "[setup_node] Disabling default postgres systemd unit ..."

systemctl stop "postgresql@${PGVER}-main" 2>/dev/null || true
systemctl disable "postgresql@${PGVER}-main" 2>/dev/null || true
systemctl stop postgresql 2>/dev/null || true
systemctl disable postgresql 2>/dev/null || true

# ── 4. Remove default PGDATA so Patroni can initdb cleanly ───────────────────
PGDATA="/var/lib/postgresql/${PGVER}/main"
if [[ -d "$PGDATA" ]]; then
    echo "[setup_node] Removing existing PGDATA at $PGDATA ..."
    rm -rf "$PGDATA"
fi

# ── 5. Install Patroni with Raft ──────────────────────────────────────────────
# Ubuntu 24.04 enforces PEP 668 (externally managed environment), so we need
# --break-system-packages.  Raft is Patroni's built-in DCS — no etcd/Consul/ZK
# required, suitable for a two-node benchmark cluster.
echo "[setup_node] Installing Patroni[raft] via pip3 ..."
pip3 install --break-system-packages --quiet 'patroni[raft]' psycopg2-binary

# ── 6. Create directories ─────────────────────────────────────────────────────
echo "[setup_node] Creating Patroni directories ..."

mkdir -p /var/lib/patroni/raft /etc/patroni
chown -R postgres:postgres /var/lib/patroni /etc/patroni

# ── 7. Install patroni.service systemd unit ───────────────────────────────────
echo "[setup_node] Installing patroni.service ..."

cat > /etc/systemd/system/patroni.service << 'SVCEOF'
[Unit]
Description=Patroni HA PostgreSQL
After=syslog.target network.target

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/local/bin/patroni /etc/patroni/patroni.yml
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
TimeoutSec=30
Restart=on-failure

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable patroni

echo "[setup_node] Node setup complete (ROLE=$NODE_ROLE)"
