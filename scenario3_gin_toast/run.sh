#!/usr/bin/env bash
# Scenario 3: GIN + TOAST bursty apply pressure
#
# Usage: bash run.sh <primary_connstr> <standby_connstr>
#
# This scenario demonstrates bursty latency spikes with remote_apply
# caused by GIN pending list flushes and TOAST operations during replay.
#
# The pattern: latency looks similar for both modes most of the time,
# but remote_apply shows periodic spikes when GIN pending lists flush.

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

PRIMARY="${1:?Usage: $0 PRIMARY_CONNSTR STANDBY_CONNSTR}"
STANDBY="${2:?Usage: $0 PRIMARY_CONNSTR STANDBY_CONNSTR}"
CLIENTS="${3:-12}"
DURATION="${4:-120}"

echo "=== Scenario 3: GIN + TOAST apply pressure ==="
echo "Primary:  $PRIMARY"
echo "Standby:  $STANDBY"
echo "Clients:  $CLIENTS"
echo "Duration: ${DURATION}s per mode"
echo ""

# --- Setup ---
echo ">>> Loading schema + data (this takes a couple minutes)..."
psql "$PRIMARY" -f "$DIR/setup.sql"
echo ">>> Waiting for standby to catch up..."
sleep 10

# --- Run for each mode ---
for MODE in remote_write remote_apply; do
    echo ""
    echo "========================================"
    echo "  synchronous_commit = ${MODE}"
    echo "========================================"
    psql "$PRIMARY" -c "ALTER SYSTEM SET synchronous_commit = '${MODE}';"
    psql "$PRIMARY" -c "SELECT pg_reload_conf();"
    sleep 2

    # Run mixed workload: 70% inserts (GIN pending list growth) + 30% updates (TOAST rewrites)
    echo "--- Mixed workload: ${CLIENTS} clients, ${DURATION}s ---"
    echo "--- (70% INSERT + 30% UPDATE with GIN/TOAST) ---"
    pgbench "$PRIMARY" \
        -f "$DIR/workload_insert.sql"@7 \
        -f "$DIR/workload_update.sql"@3 \
        -c "$CLIENTS" \
        -j "$CLIENTS" \
        -T "$DURATION" \
        -P 5 \
        --progress-timestamp \
        2>&1 | tee "/tmp/pgbench_s3_${MODE}.log"

    # Trigger a manual GIN cleanup to see the flush spike
    echo ">>> Triggering VACUUM to flush GIN pending lists..."
    time psql "$PRIMARY" -c "VACUUM tickets;" 2>&1

    # Show replication state
    psql "$PRIMARY" -f "$DIR/../common/monitor_lag.sql"
    sleep 5
done

echo ""
echo "========================================"
echo "  SUMMARY"
echo "========================================"
for MODE in remote_write remote_apply; do
    echo "--- ${MODE} ---"
    grep -E '^(latency average|latency stddev|tps)' "/tmp/pgbench_s3_${MODE}.log" || true
    echo ""
done

echo ">>> Key thing to look for:"
echo "    Compare the per-5s progress lines between modes."
echo "    remote_apply should show higher p99 latency and periodic spikes"
echo "    when GIN pending lists are flushed during replay."
