#!/usr/bin/env bash
# Usage: compare_modes.sh <primary_connstr> <pgbench_script> <clients> <duration_sec> [extra_pgbench_args]
#
# Runs the same pgbench workload twice — once with remote_write, once with
# remote_apply — and prints side-by-side latency stats.

set -euo pipefail

PRIMARY="$1"
SCRIPT="$2"
CLIENTS="${3:-8}"
DURATION="${4:-60}"
shift 4 || true
EXTRA_ARGS="${*:-}"

for MODE in remote_write remote_apply; do
    echo "========================================"
    echo "  synchronous_commit = ${MODE}"
    echo "========================================"

    psql "$PRIMARY" -c "ALTER SYSTEM SET synchronous_commit = '${MODE}';"
    psql "$PRIMARY" -c "SELECT pg_reload_conf();"
    sleep 2

    echo "--- pgbench: ${CLIENTS} clients, ${DURATION}s ---"
    pgbench "$PRIMARY" \
        -f "$SCRIPT" \
        -c "$CLIENTS" \
        -j "$CLIENTS" \
        -T "$DURATION" \
        -P 5 \
        --progress-timestamp \
        $EXTRA_ARGS \
        2>&1 | tee "/tmp/pgbench_${MODE}.log"

    echo ""
done

echo "========================================"
echo "  SUMMARY"
echo "========================================"
for MODE in remote_write remote_apply; do
    echo "--- ${MODE} ---"
    grep -E '^(transaction type|number of transactions|latency average|latency stddev|tps)' \
        "/tmp/pgbench_${MODE}.log" || true
    echo ""
done
