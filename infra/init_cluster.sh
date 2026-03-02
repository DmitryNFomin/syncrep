#!/usr/bin/env bash
# init_cluster.sh — install PG+Patroni on both nodes, form the sync cluster
#
# Runs LOCALLY on the operator's machine.  Requires:
#   - infra/hetzner.env   (written by hetzner_create.sh)
#   - infra/hetzner.conf  (your Hetzner/PG settings)
#   - SSH access to root@PRIMARY_PUBLIC_IP and root@REPLICA_PUBLIC_IP
#   - hcloud CLI on PATH
#
# Usage:
#   bash infra/init_cluster.sh

set -euo pipefail

# ── Locate dirs ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
step()  { echo -e "\n${BOLD}${CYAN}==> $*${NC}"; }
error() { echo -e "${RED}[!] ERROR:${NC} $*" >&2; exit 1; }
warn()  { echo -e "${RED}[!]${NC} $*"; }

# ── Load environment files ─────────────────────────────────────────────────────
ENV_FILE="$SCRIPT_DIR/hetzner.env"
CONF_FILE="$SCRIPT_DIR/hetzner.conf"

if [[ ! -f "$ENV_FILE" ]]; then
    error "infra/hetzner.env not found.
  Run the provisioning step first:
    bash infra/hetzner_create.sh"
fi

if [[ ! -f "$CONF_FILE" ]]; then
    error "infra/hetzner.conf not found.
  Copy the example and fill in your values:
    cp infra/hetzner.conf.example infra/hetzner.conf"
fi

# shellcheck source=/dev/null
source "$ENV_FILE"
# shellcheck source=/dev/null
source "$CONF_FILE"

# ── SSH shortcuts ─────────────────────────────────────────────────────────────
SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=30"
SSH_P="ssh $SSH_OPTS root@$PRIMARY_PUBLIC_IP"
SSH_R="ssh $SSH_OPTS root@$REPLICA_PUBLIC_IP"

info "Primary  : dmitry1  public=$PRIMARY_PUBLIC_IP  private=$PRIMARY_PRIVATE_IP"
info "Replica  : dmitry2  public=$REPLICA_PUBLIC_IP  private=$REPLICA_PRIVATE_IP"
info "PG ver   : $PGVER"

# ── Step 1: Bootstrap both nodes in parallel ──────────────────────────────────
step "Step 1/8: Bootstrapping nodes (uploading + running setup_node.sh)"

scp $SSH_OPTS "$SCRIPT_DIR/setup_node.sh" "root@$PRIMARY_PUBLIC_IP:/tmp/"
scp $SSH_OPTS "$SCRIPT_DIR/setup_node.sh" "root@$REPLICA_PUBLIC_IP:/tmp/"

info "Running setup_node.sh on both nodes in parallel ..."

$SSH_P "bash /tmp/setup_node.sh \
    '$PGVER' primary \
    '$PRIMARY_PRIVATE_IP' '$REPLICA_PRIVATE_IP' \
    '$PGPASSWORD' '$REPLICATOR_PASSWORD'" &
PID_PRIMARY=$!

$SSH_R "bash /tmp/setup_node.sh \
    '$PGVER' replica \
    '$PRIMARY_PRIVATE_IP' '$REPLICA_PRIVATE_IP' \
    '$PGPASSWORD' '$REPLICATOR_PASSWORD'" &
PID_REPLICA=$!

wait $PID_PRIMARY || error "setup_node.sh failed on dmitry1 (primary)"
wait $PID_REPLICA || error "setup_node.sh failed on dmitry2 (replica)"

info "Both nodes bootstrapped successfully"

# ── Step 2: Write patroni.yml on primary ─────────────────────────────────────
step "Step 2/8: Deploying patroni.yml on primary (dmitry1)"

$SSH_P "cat > /etc/patroni/patroni.yml" << EOF
scope: ${CLUSTER_NAME:-syncrep}
namespace: /${CLUSTER_NAME:-syncrep}/
name: dmitry1

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${PRIMARY_PRIVATE_IP}:8008

raft:
  data_dir: /var/lib/patroni/raft
  self_addr: ${PRIMARY_PRIVATE_IP}:2380
  partner_addrs:
    - ${REPLICA_PRIVATE_IP}:2380

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 104857600
    synchronous_mode: true
    synchronous_mode_strict: false
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: logical
        hot_standby: on
        max_connections: 200
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 1GB
        shared_buffers: 2GB
        effective_cache_size: 6GB
        work_mem: 16MB
        max_wal_size: 4GB
        checkpoint_timeout: 15min
        checkpoint_completion_target: 0.9
        log_min_messages: warning
        track_io_timing: on
        full_page_writes: on
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - local all all trust
    - host all all 127.0.0.1/32 trust
    - host all postgres ${PRIMARY_PRIVATE_IP}/32 trust
    - host all postgres ${REPLICA_PRIVATE_IP}/32 trust
    - host all all 0.0.0.0/0 scram-sha-256
    - host replication replicator 0.0.0.0/0 scram-sha-256

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${PRIMARY_PRIVATE_IP}:5432
  data_dir: /var/lib/postgresql/${PGVER}/main
  bin_dir: /usr/lib/postgresql/${PGVER}/bin
  pgpass: /var/lib/postgresql/.pgpass
  authentication:
    replication:
      username: replicator
      password: ${REPLICATOR_PASSWORD}
    superuser:
      username: postgres
      password: ${PGPASSWORD}
    rewind:
      username: rewind_user
      password: ${PGPASSWORD}
  parameters:
    unix_socket_directories: '/var/run/postgresql'

watchdog:
  mode: off

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF

$SSH_P "chown postgres:postgres /etc/patroni/patroni.yml"
info "patroni.yml deployed on dmitry1"

# ── Step 3: Write patroni.yml on replica ─────────────────────────────────────
step "Step 3/8: Deploying patroni.yml on replica (dmitry2)"

$SSH_R "cat > /etc/patroni/patroni.yml" << EOF
scope: ${CLUSTER_NAME:-syncrep}
namespace: /${CLUSTER_NAME:-syncrep}/
name: dmitry2

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${REPLICA_PRIVATE_IP}:8008

raft:
  data_dir: /var/lib/patroni/raft
  self_addr: ${REPLICA_PRIVATE_IP}:2380
  partner_addrs:
    - ${PRIMARY_PRIVATE_IP}:2380

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 104857600
    synchronous_mode: true
    synchronous_mode_strict: false
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: logical
        hot_standby: on
        max_connections: 200
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 1GB
        shared_buffers: 2GB
        effective_cache_size: 6GB
        work_mem: 16MB
        max_wal_size: 4GB
        checkpoint_timeout: 15min
        checkpoint_completion_target: 0.9
        log_min_messages: warning
        track_io_timing: on
        full_page_writes: on
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - local all all trust
    - host all all 127.0.0.1/32 trust
    - host all postgres ${PRIMARY_PRIVATE_IP}/32 trust
    - host all postgres ${REPLICA_PRIVATE_IP}/32 trust
    - host all all 0.0.0.0/0 scram-sha-256
    - host replication replicator 0.0.0.0/0 scram-sha-256

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${REPLICA_PRIVATE_IP}:5432
  data_dir: /var/lib/postgresql/${PGVER}/main
  bin_dir: /usr/lib/postgresql/${PGVER}/bin
  pgpass: /var/lib/postgresql/.pgpass
  authentication:
    replication:
      username: replicator
      password: ${REPLICATOR_PASSWORD}
    superuser:
      username: postgres
      password: ${PGPASSWORD}
    rewind:
      username: rewind_user
      password: ${PGPASSWORD}
  parameters:
    unix_socket_directories: '/var/run/postgresql'

watchdog:
  mode: off

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF

$SSH_R "chown postgres:postgres /etc/patroni/patroni.yml"
info "patroni.yml deployed on dmitry2"

# ── Step 4+5: Start Patroni on BOTH nodes simultaneously, wait for cluster ───
# With 2-node Raft, quorum requires both peers — starting them sequentially
# causes patronictl to block indefinitely.  Start both, then poll.
step "Step 4/8: Starting Patroni on both nodes simultaneously"

$SSH_P "systemctl start patroni || true"
$SSH_R "systemctl start patroni || true"
info "Patroni started on both nodes — waiting for Leader election (timeout 120 s) ..."

# Use journalctl on primary to check for leader — patronictl needs quorum too.
DEADLINE=$(( $(date +%s) + 120 ))
LEADER_FOUND=0
while (( $(date +%s) < DEADLINE )); do
    if $SSH_P "journalctl -u patroni -n 50 --no-pager 2>/dev/null | grep -q 'promoted self to leader\|acquired session lock\|Lock owner: dmitry1'"; then
        info "dmitry1 elected as Leader"
        LEADER_FOUND=1
        break
    fi
    sleep 3
done

if [[ $LEADER_FOUND -eq 0 ]]; then
    warn "Timed out waiting for Leader election.  Checking logs..."
    $SSH_P "journalctl -u patroni -n 30 --no-pager 2>/dev/null" || true
    exit 1
fi

step "Step 5/8: Waiting for replica to join as sync standby (timeout 120 s)"

DEADLINE=$(( $(date +%s) + 120 ))
STANDBY_FOUND=0
while (( $(date +%s) < DEADLINE )); do
    STATUS=$($SSH_P "sudo -u postgres psql -At \
        -c \"SELECT count(*) FROM pg_stat_replication WHERE sync_state IN ('sync','quorum');\" \
        2>/dev/null" 2>/dev/null || echo "0")
    if [[ "${STATUS}" -ge 1 ]]; then
        info "Sync standby confirmed via pg_stat_replication"
        STANDBY_FOUND=1
        break
    fi
    sleep 5
done

if [[ $STANDBY_FOUND -eq 0 ]]; then
    warn "Replica not yet in pg_stat_replication — may still be streaming base backup."
    warn "Check: ssh root@$REPLICA_PUBLIC_IP 'journalctl -u patroni -n 50'"
    # Not fatal — continue and verify in Step 7.
fi

# ── Step 6: Create bench database and configure standby ───────────────────────
step "Step 6/8: Creating bench database and tuning standby"

# Create the bench database (idempotent — ignore error if already exists)
$SSH_P "sudo -u postgres psql -c 'CREATE DATABASE bench;' 2>/dev/null || true"
info "Database 'bench' ready on primary"

# max_standby_streaming_delay = -1
#   Prevents PostgreSQL from cancelling standby queries to let WAL replay
#   proceed.  Required for conflict scenarios (S2, S7, S8, S9) where the test
#   intentionally holds replay blocked.
#
# hot_standby_feedback = off
#   When enabled, the standby would tell the primary which XIDs are still
#   active, causing the primary's VACUUM to delay row removal — which would
#   prevent the HOT/conflict WAL that those scenarios depend on.
$SSH_R "sudo -u postgres psql \
    -c \"ALTER SYSTEM SET max_standby_streaming_delay = '-1';\" \
    -c 'SELECT pg_reload_conf();'"
info "max_standby_streaming_delay = -1 on replica"

$SSH_R "sudo -u postgres psql \
    -c \"ALTER SYSTEM SET hot_standby_feedback = off;\" \
    -c 'SELECT pg_reload_conf();'"
info "hot_standby_feedback = off on replica"

# ── Step 7: Show cluster status ───────────────────────────────────────────────
step "Step 7/8: Cluster status"

echo ""
$SSH_P "patronictl -c /etc/patroni/patroni.yml list" || true
echo ""
$SSH_P "sudo -u postgres psql -c \
    'SELECT application_name, sync_state, write_lag, replay_lag \
     FROM pg_stat_replication;'" || true

# ── Step 8: Write syncrep.conf ────────────────────────────────────────────────
step "Step 8/8: Writing syncrep.conf"

# SQL_DIR must be evaluated locally (no subshell inside the heredoc variable)
LOCAL_SQL_DIR="$(cd "$REPO_ROOT" && pwd)"

cat > "$REPO_ROOT/syncrep.conf" << CONFEOF
# syncrep.conf — auto-generated by infra/init_cluster.sh
# Re-run init_cluster.sh to regenerate, or edit manually.
PRIMARY_HOST="$PRIMARY_PUBLIC_IP"
PRIMARY_PORT="5432"
STANDBY_HOST="$REPLICA_PUBLIC_IP"
STANDBY_PORT="5432"
PGUSER="postgres"
PGPASSWORD="$PGPASSWORD"
PGDATABASE="bench"
SQL_DIR="$LOCAL_SQL_DIR"
RESULTS_DIR="/tmp/syncrep_results"
CONFEOF

info "syncrep.conf written to $REPO_ROOT/syncrep.conf"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}Cluster initialised successfully.${NC}"
echo ""
echo "  Primary  (Leader)        : $PRIMARY_PUBLIC_IP:5432"
echo "  Replica  (Sync Standby)  : $REPLICA_PUBLIC_IP:5432"
echo ""
echo "syncrep.conf written.  To run benchmarks:"
echo ""
echo "  source syncrep.conf && bash setup_patroni_env.sh   # verify cluster"
echo "  source syncrep.conf && bash run.sh                 # all scenarios"
echo "  source syncrep.conf && bash run.sh 1 5             # scenarios 1–5"
echo ""
echo "To SSH into the nodes:"
echo "  ssh root@$PRIMARY_PUBLIC_IP   # dmitry1 (primary)"
echo "  ssh root@$REPLICA_PUBLIC_IP   # dmitry2 (replica)"
echo ""
echo "To tear down: bash infra/hetzner_destroy.sh"
echo ""
