#!/usr/bin/env bash
# Scenario 2: Block apply with standby query conflict
#
# This test demonstrates how a single long-running query on the standby
# can completely stall remote_apply commits on the primary.
#
# Usage: bash run.sh <primary_connstr> <standby_connstr>
#
# The test:
# 1. Loads data, runs churn to create dead tuples
# 2. Starts a long REPEATABLE READ query on the standby (holds snapshot)
# 3. VACUUMs on the primary (generates conflict WAL)
# 4. Runs pgbench with remote_apply — transactions stall
# 5. Compares with remote_write — transactions fly through

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

PRIMARY="${1:?Usage: $0 PRIMARY_CONNSTR STANDBY_CONNSTR}"
STANDBY="${2:?Usage: $0 PRIMARY_CONNSTR STANDBY_CONNSTR}"

echo "=== Scenario 2: Standby query blocks WAL replay ==="
echo "Primary: $PRIMARY"
echo "Standby: $STANDBY"
echo ""

# --- Pre-flight checks ---
DELAY=$(psql "$STANDBY" -tAc "SHOW max_standby_streaming_delay;" 2>/dev/null || echo "unknown")
HSF=$(psql "$STANDBY" -tAc "SHOW hot_standby_feedback;" 2>/dev/null || echo "unknown")
echo "Standby max_standby_streaming_delay = $DELAY"
echo "Standby hot_standby_feedback = $HSF"
echo ""

if [ "$DELAY" != "-1" ]; then
    echo "WARNING: max_standby_streaming_delay should be -1 for this test."
    echo "On the standby, set:"
    echo "  ALTER SYSTEM SET max_standby_streaming_delay = '-1';"
    echo "  SELECT pg_reload_conf();"
    echo ""
fi

if [ "$HSF" = "on" ]; then
    echo "WARNING: hot_standby_feedback = on will PREVENT the conflict!"
    echo "On the standby, set:"
    echo "  ALTER SYSTEM SET hot_standby_feedback = off;"
    echo "  SELECT pg_reload_conf();"
    echo ""
fi

# --- Setup ---
echo ">>> Loading data..."
psql "$PRIMARY" -f "$DIR/setup.sql"
sleep 3

echo ">>> Running churn workload to create dead tuples..."
pgbench "$PRIMARY" \
    -f "$DIR/workload_churn.sql" \
    -c 4 -j 4 -T 30 \
    --no-vacuum \
    > /dev/null 2>&1
echo "    Done. Dead tuples created."

# Wait for standby to catch up
echo ">>> Waiting for standby to catch up..."
sleep 5

# ========================
# PHASE A: remote_write (baseline — should be fast)
# ========================
echo ""
echo "========================================"
echo "  PHASE A: remote_write (baseline)"
echo "========================================"
psql "$PRIMARY" -c "ALTER SYSTEM SET synchronous_commit = 'remote_write';"
psql "$PRIMARY" -c "SELECT pg_reload_conf();"
sleep 1

# Start the blocking query on standby (background)
echo ">>> Starting blocking REPEATABLE READ query on standby..."
psql "$STANDBY" -f "$DIR/standby_blocker.sql" &
BLOCKER_PID=$!
sleep 2  # let the snapshot establish

# VACUUM to create conflicting WAL
echo ">>> Running VACUUM on primary (creates conflict WAL)..."
psql "$PRIMARY" -c "VACUUM VERBOSE orders;" 2>&1 | tail -3
sleep 1

echo ">>> Running steady workload for 60s with remote_write..."
pgbench "$PRIMARY" \
    -f "$DIR/workload_steady.sql" \
    -c 8 -j 8 -T 60 \
    -P 5 \
    --progress-timestamp \
    2>&1 | tee /tmp/pgbench_s2_remote_write.log

# Wait for blocker to finish
wait $BLOCKER_PID 2>/dev/null || true
sleep 5  # let replay catch up

# ========================
# PHASE B: remote_apply (should stall when replay is blocked)
# ========================

# Need fresh dead tuples for a new conflict
echo ""
echo ">>> Creating fresh dead tuples for Phase B..."
pgbench "$PRIMARY" \
    -f "$DIR/workload_churn.sql" \
    -c 4 -j 4 -T 20 \
    --no-vacuum \
    > /dev/null 2>&1
sleep 3

echo "========================================"
echo "  PHASE B: remote_apply (expect stalls)"
echo "========================================"
psql "$PRIMARY" -c "ALTER SYSTEM SET synchronous_commit = 'remote_apply';"
psql "$PRIMARY" -c "SELECT pg_reload_conf();"
sleep 1

# Start the blocking query on standby again
echo ">>> Starting blocking REPEATABLE READ query on standby..."
psql "$STANDBY" -f "$DIR/standby_blocker.sql" &
BLOCKER_PID=$!
sleep 2

# VACUUM to create conflicting WAL
echo ">>> Running VACUUM on primary (creates conflict WAL)..."
psql "$PRIMARY" -c "VACUUM VERBOSE orders;" 2>&1 | tail -3
sleep 1

echo ">>> Running steady workload for 60s with remote_apply..."
echo ">>> (Expect latency spikes / complete stalls!)"
pgbench "$PRIMARY" \
    -f "$DIR/workload_steady.sql" \
    -c 8 -j 8 -T 60 \
    -P 5 \
    --progress-timestamp \
    2>&1 | tee /tmp/pgbench_s2_remote_apply.log

wait $BLOCKER_PID 2>/dev/null || true

# ========================
# Summary
# ========================
echo ""
echo "========================================"
echo "  SUMMARY"
echo "========================================"
echo "--- remote_write (should be smooth) ---"
grep -E '^(latency average|latency stddev|tps)' /tmp/pgbench_s2_remote_write.log || true
echo ""
echo "--- remote_apply (should show stalls) ---"
grep -E '^(latency average|latency stddev|tps)' /tmp/pgbench_s2_remote_apply.log || true
echo ""
echo ">>> Check the per-5s progress lines above:"
echo "    remote_write should have stable latency."
echo "    remote_apply should show latency spikes during the"
echo "    90-second window when the standby query blocks replay."
echo ""
echo ">>> Final replication state:"
psql "$PRIMARY" -f "$DIR/../common/monitor_lag.sql"
