#!/usr/bin/env bash
# Scenario 1: Saturate apply with index-heavy updates
#
# Usage: bash run.sh <primary_connstr> <standby_connstr>
#
# Example:
#   bash run.sh "host=primary dbname=bench" "host=standby dbname=bench"

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

PRIMARY="${1:?Usage: $0 PRIMARY_CONNSTR STANDBY_CONNSTR}"
STANDBY="${2:?Usage: $0 PRIMARY_CONNSTR STANDBY_CONNSTR}"
CLIENTS="${3:-16}"
DURATION="${4:-120}"

echo "=== Scenario 1: Index-heavy UPDATE saturation ==="
echo "Primary:  $PRIMARY"
echo "Standby:  $STANDBY"
echo "Clients:  $CLIENTS"
echo "Duration: ${DURATION}s per mode"
echo ""

# --- Pre-flight: ensure synchronous_standby_names is set ---
SYNC_NAMES=$(psql "$PRIMARY" -tAc "SHOW synchronous_standby_names;" 2>/dev/null)
if [ -z "$SYNC_NAMES" ]; then
    echo "WARNING: synchronous_standby_names is empty."
    echo "Set it on the primary first, e.g.:"
    echo "  ALTER SYSTEM SET synchronous_standby_names = 'walreceiver';"
    echo "  SELECT pg_reload_conf();"
    exit 1
fi
echo "synchronous_standby_names = $SYNC_NAMES"
echo ""

# --- Setup ---
echo ">>> Loading schema + data (this takes a minute)..."
psql "$PRIMARY" -f "$DIR/setup.sql"

echo ">>> Waiting for standby to catch up..."
sleep 5
psql "$PRIMARY" -tAc "
  SELECT 'replay_lag_bytes: ' || (sent_lsn - replay_lsn)::text
  FROM pg_stat_replication LIMIT 1;
"

# --- Checkpoint on primary so first touches after start generate FPIs ---
echo ">>> Checkpoint to maximize Full Page Images on first touch..."
psql "$PRIMARY" -c "CHECKPOINT;"
sleep 2

# --- Run comparison ---
bash "$DIR/../common/compare_modes.sh" \
    "$PRIMARY" \
    "$DIR/workload.sql" \
    "$CLIENTS" \
    "$DURATION"

echo ""
echo ">>> Final replication state:"
psql "$PRIMARY" -f "$DIR/../common/monitor_lag.sql"
