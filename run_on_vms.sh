#!/usr/bin/env bash
# run_on_vms.sh — Run all 8 scenarios on real VMs
#
# Execute on the PRIMARY VM:
#   bash /root/syncrep/run_on_vms.sh          # all scenarios
#   bash /root/syncrep/run_on_vms.sh 4 7      # specific scenarios
#
# Prereqs:
#   - sync replication configured (synchronous_standby_names = '*')
#   - bench database created
#   - standby: max_standby_streaming_delay = -1, hot_standby_feedback = off
#   - scenario files in /root/syncrep/
set -euo pipefail

STANDBY_HOST="46.225.119.93"
PSQL="sudo -u postgres psql -d bench -v ON_ERROR_STOP=1"
PSQL_S="sudo -u postgres psql -h $STANDBY_HOST -d bench"
SQL_DIR="/tmp/syncrep"
RESULTS_DIR="/tmp/syncrep/results"
mkdir -p "$RESULTS_DIR"

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}>>>${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
err()  { echo -e "${RED}ERROR:${NC} $*"; }
hdr()  { echo -e "\n${BOLD}${CYAN}════════════════════════════════════════${NC}"; \
         echo -e "${BOLD}${CYAN}  $*${NC}"; \
         echo -e "${BOLD}${CYAN}════════════════════════════════════════${NC}"; }

# ── helpers ──────────────────────────────────────────────────────────────────
wait_for_catchup() {
    log "Waiting for replay to catch up..."
    local max_wait=${1:-180}
    for _ in $(seq 1 "$max_wait"); do
        local lag
        lag=$($PSQL -tAc "
            SELECT COALESCE(
              (SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)
               FROM pg_stat_replication LIMIT 1), -1)::bigint;" 2>/dev/null || echo "-1")
        if [ "$lag" != "-1" ] && [ "$lag" -lt 65536 ] 2>/dev/null; then
            log "Replay caught up (lag=${lag} bytes)"
            return 0
        fi
        sleep 1
    done
    warn "Replay did not fully catch up (lag=$lag bytes) — continuing anyway"
}

set_sync_mode() {
    $PSQL -c "ALTER SYSTEM SET synchronous_commit = '$1';" >/dev/null
    $PSQL -c "SELECT pg_reload_conf();" >/dev/null
    sleep 1
    log "synchronous_commit = $1"
}

show_repl() {
    echo "  ── pg_stat_replication ──"
    $PSQL -c "
      SELECT pid, application_name, sync_state,
             write_lag, flush_lag, replay_lag,
             replay_lag - write_lag AS apply_delta,
             pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
      FROM pg_stat_replication;" 2>/dev/null || true
}

extract_avg_latency() {
    grep 'latency average' "$1" 2>/dev/null | head -1 | awk -F'= ' '{print $2}' | awk '{print $1}'
}

extract_tps() {
    grep '^tps' "$1" 2>/dev/null | head -1 | awk -F'= ' '{print $2}' | awk '{print $1}'
}

kill_standby_sessions() {
    $PSQL_S -tAc "
      SELECT pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE pid != pg_backend_pid()
        AND query NOT LIKE '%pg_terminate_backend%'
        AND backend_type = 'client backend';" >/dev/null 2>&1 || true
}

print_comparison() {
    local label="$1" rw_log="$2" ra_log="$3" pass_threshold="$4"

    local lat_rw lat_ra tps_rw tps_ra
    lat_rw=$(extract_avg_latency "$rw_log")
    lat_ra=$(extract_avg_latency "$ra_log")
    tps_rw=$(extract_tps "$rw_log")
    tps_ra=$(extract_tps "$ra_log")

    hdr "$label — RESULTS"
    printf "  %-20s %12s %12s\n"   ""                "remote_write" "remote_apply"
    printf "  %-20s %12s %12s\n"   "avg latency (ms)" "$lat_rw"     "$lat_ra"
    printf "  %-20s %12s %12s\n"   "TPS"              "$tps_rw"     "$tps_ra"

    if [ -n "$lat_rw" ] && [ -n "$lat_ra" ]; then
        local ratio
        ratio=$(awk "BEGIN {printf \"%.1f\", $lat_ra / $lat_rw}")
        echo ""
        echo -e "  Latency ratio (apply/write): ${BOLD}${ratio}x${NC}"
        if awk "BEGIN {exit !($lat_ra > $lat_rw * $pass_threshold)}"; then
            echo -e "  ${GREEN}PASS${NC} — remote_apply latency is measurably higher"
        else
            echo -e "  ${YELLOW}MARGINAL${NC} — delta is small"
        fi
    fi
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 1: Index-heavy UPDATE saturation
# ══════════════════════════════════════════════════════════════════════════════
scenario1() {
    hdr "SCENARIO 1: Index-heavy UPDATE saturation"
    echo "  Strategy: 32 clients UPDATE rows with 16 indexes."
    echo "  Single-threaded replay can't keep up → remote_apply stalls."
    echo ""

    set_sync_mode "local"
    log "Loading data (2M rows, 16 indexes — takes ~60s)..."
    $PSQL -f $SQL_DIR/scenario1_saturate_indexes/setup.sql >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup 300

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"
        $PSQL -c "CHECKPOINT;" >/dev/null
        sleep 2

        log "Running pgbench (32 clients, 45s)..."
        sudo -u postgres pgbench --no-vacuum bench \
            -f $SQL_DIR/scenario1_saturate_indexes/workload.sql \
            -c 32 -j 8 -T 45 -P 5 --progress-timestamp 2>&1 \
            | tee "$RESULTS_DIR/s1_${MODE}.log"

        show_repl
        wait_for_catchup 300
        echo ""
    done

    print_comparison "SCENARIO 1" "$RESULTS_DIR/s1_remote_write.log" \
                     "$RESULTS_DIR/s1_remote_apply.log" 1.3
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 2: Blocked replay via standby query conflict
# ══════════════════════════════════════════════════════════════════════════════
scenario2() {
    hdr "SCENARIO 2: Blocked replay via standby query conflict"
    echo "  Strategy: standby REPEATABLE READ query holds snapshot;"
    echo "  churn + VACUUM on primary creates conflicting prune WAL;"
    echo "  replay pauses → remote_apply commits freeze completely."
    echo ""

    set_sync_mode "local"
    log "Loading orders (500K rows)..."
    $PSQL -f $SQL_DIR/scenario2_blocked_conflict/setup.sql >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"

        # Churn (always under remote_write to avoid deadlock)
        set_sync_mode "remote_write"
        log "Running order churn (30s, 4 clients)..."
        sudo -u postgres pgbench --no-vacuum bench \
            -f $SQL_DIR/scenario2_blocked_conflict/workload_churn.sql \
            -c 4 -j 4 -T 30 2>&1 | tail -1
        sleep 5

        # Start blocker on standby
        log "Starting analytics query on standby (holds snapshot for ~90s)..."
        $PSQL_S -f $SQL_DIR/scenario2_blocked_conflict/standby_blocker.sql &
        ANALYTICS_PID=$!
        sleep 3

        local active
        active=$($PSQL_S -tAc \
            "SELECT count(*) FROM pg_stat_activity
             WHERE query LIKE '%pg_sleep%' AND state='active';" 2>/dev/null || echo 0)
        log "Active analytics sessions on standby: $active"

        # VACUUM with local commit
        set_sync_mode "$MODE"
        log "VACUUM orders (generates conflict WAL)..."
        $PSQL -c "SET synchronous_commit TO local" \
              -c "VACUUM orders" 2>&1 | tail -1
        sleep 1
        show_repl

        # Run probe
        log "Starting probe pgbench (8 clients, 30s)..."
        sudo -u postgres pgbench --no-vacuum bench \
            -f $SQL_DIR/scenario2_blocked_conflict/workload_steady.sql \
            -c 8 -j 4 -T 30 -P 5 --progress-timestamp 2>&1 \
            | tee "$RESULTS_DIR/s2_${MODE}.log"

        show_repl
        kill_standby_sessions
        wait $ANALYTICS_PID 2>/dev/null || true
        sleep 5
        wait_for_catchup 120

        # Re-create dead tuples for next run
        if [ "$MODE" = "remote_write" ]; then
            log "Re-creating order churn for next run..."
            set_sync_mode "remote_write"
            sudo -u postgres pgbench --no-vacuum bench \
                -f $SQL_DIR/scenario2_blocked_conflict/workload_churn.sql \
                -c 4 -j 4 -T 20 2>&1 >/dev/null
            wait_for_catchup
            $PSQL -c "CHECKPOINT;" >/dev/null
            sleep 2
        fi
        echo ""
    done

    print_comparison "SCENARIO 2" "$RESULTS_DIR/s2_remote_write.log" \
                     "$RESULTS_DIR/s2_remote_apply.log" 5.0
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 3: GIN + TOAST bursty replay
# ══════════════════════════════════════════════════════════════════════════════
scenario3() {
    hdr "SCENARIO 3: GIN + TOAST bursty replay"
    echo "  Strategy: 70% INSERT / 30% UPDATE with large TOAST bodies"
    echo "  and 4 GIN indexes (gin_pending_list_limit=64)."
    echo ""

    set_sync_mode "local"
    log "Loading data (300K rows, 4 GIN indexes — takes ~120s)..."
    $PSQL -f $SQL_DIR/scenario3_gin_toast/setup.sql >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup 300

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"
        $PSQL -c "CHECKPOINT;" >/dev/null
        sleep 2

        log "Running mixed workload (12 clients, 45s)..."
        sudo -u postgres pgbench --no-vacuum bench \
            -f $SQL_DIR/scenario3_gin_toast/workload_insert.sql@7 \
            -f $SQL_DIR/scenario3_gin_toast/workload_update.sql@3 \
            -c 12 -j 4 -T 45 -P 5 --progress-timestamp 2>&1 \
            | tee "$RESULTS_DIR/s3_${MODE}.log"

        show_repl
        wait_for_catchup 300
        echo ""
    done

    print_comparison "SCENARIO 3" "$RESULTS_DIR/s3_remote_write.log" \
                     "$RESULTS_DIR/s3_remote_apply.log" 1.2
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 4: Schema migration (UPDATE + CREATE INDEX)
# ══════════════════════════════════════════════════════════════════════════════
scenario4() {
    hdr "SCENARIO 4: Schema migration"
    echo "  Strategy: UPDATE 2M rows + CREATE INDEX while OLTP runs."
    echo "  The UPDATE generates a massive WAL burst (~1GB); standby's"
    echo "  single-threaded replay can't keep up → remote_apply commits stall."
    echo ""

    set_sync_mode "local"
    log "Loading data (2M rows — takes ~30s)..."
    $PSQL -f $SQL_DIR/scenario4_create_index/setup.sql >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"
        $PSQL -c "CHECKPOINT;" >/dev/null
        sleep 2

        # Drop leftover indexes
        $PSQL -c "SET synchronous_commit TO local" \
              -c "DROP INDEX IF EXISTS events_ts_user" \
              -c "DROP INDEX IF EXISTS events_svc_dur" >/dev/null 2>&1
        sleep 3

        log "Starting probe pgbench (8 clients, 30s)..."
        sudo -u postgres pgbench --no-vacuum bench \
            -f $SQL_DIR/scenario4_create_index/workload_probe.sql \
            -c 8 -j 4 -T 30 -P 5 --progress-timestamp 2>&1 \
            > "$RESULTS_DIR/s4_${MODE}.log" &
        PGBENCH_PID=$!

        sleep 5   # baseline

        log "Running migration (UPDATE + CREATE INDEX, sync_commit=local)..."
        local t0=$(date +%s)

        $PSQL -c "SET synchronous_commit TO local" \
              -c "SET maintenance_work_mem = '256MB'" \
              -c "UPDATE events SET payload = upper(payload)" 2>&1
        log "  UPDATE done ($(( $(date +%s) - t0 ))s elapsed)"

        $PSQL -c "SET synchronous_commit TO local" \
              -c "CREATE INDEX events_ts_user ON events(ts, user_id)" 2>&1
        log "  btree index done ($(( $(date +%s) - t0 ))s elapsed)"

        $PSQL -c "SET synchronous_commit TO local" \
              -c "CREATE INDEX events_svc_dur ON events(service, duration_ms)" 2>&1
        log "  all indexes done ($(( $(date +%s) - t0 ))s elapsed)"

        log "Migration done. Waiting for pgbench to finish..."
        wait $PGBENCH_PID || true

        show_repl
        echo ""

        # Reset for next mode
        $PSQL -c "SET synchronous_commit TO local" \
              -c "DROP INDEX IF EXISTS events_ts_user" \
              -c "DROP INDEX IF EXISTS events_svc_dur" \
              -c "UPDATE events SET payload = lower(payload)" >/dev/null 2>&1
        wait_for_catchup 180
    done

    print_comparison "SCENARIO 4" "$RESULTS_DIR/s4_remote_write.log" \
                     "$RESULTS_DIR/s4_remote_apply.log" 1.3
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 5: Bulk INSERT (ETL)
# ══════════════════════════════════════════════════════════════════════════════
scenario5() {
    hdr "SCENARIO 5: Bulk INSERT into indexed table (ETL)"
    echo "  Strategy: INSERT...SELECT 2M rows into table with 4 indexes"
    echo "  while OLTP probe runs. Bulk WAL floods replay."
    echo ""

    set_sync_mode "local"
    log "Loading schema (empty indexed table + probe)..."
    $PSQL -f $SQL_DIR/scenario5_bulk_load/setup.sql >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"

        # Clear data from previous run
        $PSQL -c "SET synchronous_commit TO local" \
              -c "TRUNCATE logs" >/dev/null 2>&1
        wait_for_catchup
        $PSQL -c "CHECKPOINT;" >/dev/null
        sleep 2

        log "Starting probe pgbench (8 clients, 60s)..."
        sudo -u postgres pgbench --no-vacuum bench \
            -f $SQL_DIR/scenario5_bulk_load/workload_probe.sql \
            -c 8 -j 4 -T 60 -P 5 --progress-timestamp 2>&1 \
            > "$RESULTS_DIR/s5_${MODE}.log" &
        PGBENCH_PID=$!

        sleep 2   # baseline

        log "Bulk loading 2M rows (sync_commit=local)..."
        local t0=$(date +%s)
        $PSQL <<'EOSQL'
SET synchronous_commit TO local;
INSERT INTO logs (ts, level, service, message, trace_id)
SELECT
    now() - make_interval(days => (random() * 30)::int),
    (ARRAY['DEBUG','INFO','WARN','ERROR','FATAL'])[1+(random()*4)::int],
    (ARRAY['auth','billing','search','export','notify','gateway','worker','scheduler'])[1+(random()*7)::int],
    'Request processed: ' || md5(random()::text) || ' status=' || (200 + (random()*300)::int) || ' duration=' || (random()*1000)::int || 'ms ' || md5(random()::text),
    md5(random()::text)
FROM generate_series(1, 2000000);
EOSQL
        log "  Bulk load done ($(( $(date +%s) - t0 ))s)"

        log "Waiting for pgbench to finish..."
        wait $PGBENCH_PID || true

        show_repl
        echo ""
    done

    wait_for_catchup
    print_comparison "SCENARIO 5" "$RESULTS_DIR/s5_remote_write.log" \
                     "$RESULTS_DIR/s5_remote_apply.log" 1.3
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 6: FPI storm
# ══════════════════════════════════════════════════════════════════════════════
scenario6() {
    hdr "SCENARIO 6: FPI storm (frequent checkpoints)"
    echo "  Strategy: checkpoint_timeout=30s + random scattered UPDATEs."
    echo "  After each checkpoint, every page touch generates 8KB FPI."
    echo ""

    set_sync_mode "local"
    log "Loading data (2M rows, fillfactor=50 — takes ~30s)..."
    $PSQL -f $SQL_DIR/scenario6_fpi_storm/setup.sql >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup

    # Short checkpoint interval
    log "Setting checkpoint_timeout = 30s..."
    $PSQL -c "ALTER SYSTEM SET checkpoint_timeout = '30s';" >/dev/null
    $PSQL -c "SELECT pg_reload_conf();" >/dev/null

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"
        $PSQL -c "CHECKPOINT;" >/dev/null
        sleep 2

        log "Running pgbench (24 clients, 60s)..."
        sudo -u postgres pgbench --no-vacuum bench \
            -f $SQL_DIR/scenario6_fpi_storm/workload.sql \
            -c 24 -j 8 -T 60 -P 5 --progress-timestamp 2>&1 \
            | tee "$RESULTS_DIR/s6_${MODE}.log"

        show_repl
        wait_for_catchup
        echo ""
    done

    # Restore
    log "Restoring checkpoint_timeout = 5min..."
    $PSQL -c "ALTER SYSTEM SET checkpoint_timeout = '5min';" >/dev/null
    $PSQL -c "SELECT pg_reload_conf();" >/dev/null

    print_comparison "SCENARIO 6" "$RESULTS_DIR/s6_remote_write.log" \
                     "$RESULTS_DIR/s6_remote_apply.log" 1.3
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 7: Reporting query blocks replay (cross-table)
# ══════════════════════════════════════════════════════════════════════════════
scenario7() {
    hdr "SCENARIO 7: Reporting query blocks replay (cross-table)"
    echo "  Strategy: standby analytics query on 'orders' table holds snapshot;"
    echo "  churn + VACUUM on primary creates conflicting prune WAL;"
    echo "  replay pauses → remote_apply commits to ANY table freeze completely."
    echo ""

    set_sync_mode "local"
    log "Loading orders (500K rows) + probe table..."
    $PSQL -f $SQL_DIR/scenario2_blocked_conflict/setup.sql >/dev/null 2>&1
    $PSQL -f $SQL_DIR/scenario7_reporting_conflict/setup_probe.sql >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"

        set_sync_mode "remote_write"
        log "Running order churn (30s, 4 clients)..."
        sudo -u postgres pgbench --no-vacuum bench \
            -f $SQL_DIR/scenario2_blocked_conflict/workload_churn.sql \
            -c 4 -j 4 -T 30 2>&1 | tail -1
        sleep 5

        log "Starting analytics query on standby (holds snapshot for ~90s)..."
        $PSQL_S -f $SQL_DIR/scenario2_blocked_conflict/standby_blocker.sql &
        ANALYTICS_PID=$!
        sleep 3

        local active
        active=$($PSQL_S -tAc \
            "SELECT count(*) FROM pg_stat_activity
             WHERE query LIKE '%pg_sleep%' AND state='active';" 2>/dev/null || echo 0)
        log "Active analytics sessions on standby: $active"

        set_sync_mode "$MODE"
        log "VACUUM orders (generates conflict WAL)..."
        $PSQL -c "SET synchronous_commit TO local" \
              -c "VACUUM orders" 2>&1 | tail -1
        sleep 1
        show_repl

        log "Starting probe pgbench on probe_s7 (8 clients, 60s)..."
        sudo -u postgres pgbench --no-vacuum bench \
            -f $SQL_DIR/scenario7_reporting_conflict/workload_probe.sql \
            -c 8 -j 4 -T 60 -P 5 --progress-timestamp 2>&1 \
            | tee "$RESULTS_DIR/s7_${MODE}.log"

        show_repl
        kill_standby_sessions
        wait $ANALYTICS_PID 2>/dev/null || true
        sleep 5
        wait_for_catchup 120

        if [ "$MODE" = "remote_write" ]; then
            log "Re-creating order churn for next run..."
            set_sync_mode "remote_write"
            sudo -u postgres pgbench --no-vacuum bench \
                -f $SQL_DIR/scenario2_blocked_conflict/workload_churn.sql \
                -c 4 -j 4 -T 20 2>&1 >/dev/null
            wait_for_catchup
            $PSQL -c "CHECKPOINT;" >/dev/null
            sleep 2
        fi
        echo ""
    done

    print_comparison "SCENARIO 7" "$RESULTS_DIR/s7_remote_write.log" \
                     "$RESULTS_DIR/s7_remote_apply.log" 5.0
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 8: Table rewrite (VACUUM FULL + lock conflict)
# ══════════════════════════════════════════════════════════════════════════════
scenario8() {
    hdr "SCENARIO 8: Table rewrite (VACUUM FULL + lock conflict)"
    echo "  Strategy: standby read query holds AccessShareLock on 'bloated';"
    echo "  VACUUM FULL acquires AccessExclusiveLock → lock conflict WAL"
    echo "  blocks ALL replay → remote_apply commits freeze completely."
    echo ""

    set_sync_mode "local"
    log "Loading data (3M rows, 50% deleted — takes ~60s)..."
    $PSQL -f $SQL_DIR/scenario8_table_rewrite/setup.sql >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup 300

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        wait_for_catchup 120

        # Start standby blocker
        set_sync_mode "remote_write"
        log "Starting standby read query on bloated (holds lock for ~60s)..."
        $PSQL_S -f $SQL_DIR/scenario8_table_rewrite/standby_blocker.sql &
        BLOCKER_PID=$!
        sleep 3

        local active
        active=$($PSQL_S -tAc \
            "SELECT count(*) FROM pg_stat_activity
             WHERE query LIKE '%pg_sleep%' AND state='active';" 2>/dev/null || echo 0)
        log "Active blocker sessions on standby: $active"

        set_sync_mode "$MODE"
        $PSQL -c "CHECKPOINT;" >/dev/null
        sleep 1

        log "Starting probe pgbench (8 clients, 45s)..."
        sudo -u postgres pgbench --no-vacuum bench \
            -f $SQL_DIR/scenario8_table_rewrite/workload_probe.sql \
            -c 8 -j 4 -T 45 -P 5 --progress-timestamp 2>&1 \
            > "$RESULTS_DIR/s8_${MODE}.log" &
        PGBENCH_PID=$!

        sleep 2   # baseline

        log "Running VACUUM FULL + CLUSTER + REINDEX (sync_commit=local)..."
        local t0=$(date +%s)
        $PSQL -c "SET synchronous_commit TO local" \
              -c "VACUUM FULL bloated" 2>&1
        log "  VACUUM FULL done ($(( $(date +%s) - t0 ))s elapsed)"

        $PSQL -c "SET synchronous_commit TO local" \
              -c "CLUSTER bloated USING bloated_pkey" 2>&1
        log "  CLUSTER done ($(( $(date +%s) - t0 ))s elapsed)"

        $PSQL -c "SET synchronous_commit TO local" \
              -c "REINDEX TABLE bloated" 2>&1
        log "  REINDEX done ($(( $(date +%s) - t0 ))s elapsed)"

        log "Waiting for pgbench to finish..."
        wait $PGBENCH_PID || true

        show_repl

        kill_standby_sessions
        wait $BLOCKER_PID 2>/dev/null || true
        sleep 5
        wait_for_catchup 180
        echo ""

        # Re-create bloat for next mode
        if [ "$MODE" = "remote_write" ]; then
            log "Re-creating table bloat for next run (takes ~60s)..."
            $PSQL <<'EOSQL'
SET synchronous_commit TO local;
INSERT INTO bloated SELECT i, 'pending', repeat(md5(i::text), 10), repeat(md5(i::text), 5), now()
FROM generate_series(2, 3000000, 2) i
ON CONFLICT (id) DO NOTHING;
DELETE FROM bloated WHERE id % 2 = 0;
EOSQL
            wait_for_catchup 180
            $PSQL -c "CHECKPOINT;" >/dev/null
            sleep 2
        fi
    done

    print_comparison "SCENARIO 8" "$RESULTS_DIR/s8_remote_write.log" \
                     "$RESULTS_DIR/s8_remote_apply.log" 2.0
}

# ── MAIN ─────────────────────────────────────────────────────────────────────
main() {
    # Verify sync replication
    local sync_state
    sync_state=$($PSQL -tAc "SELECT sync_state FROM pg_stat_replication LIMIT 1;" 2>/dev/null || echo "")
    if [ "$sync_state" != "sync" ] && [ "$sync_state" != "quorum" ]; then
        err "Replication is not synchronous (sync_state=$sync_state). Aborting."
        exit 1
    fi
    log "Replication OK (sync_state=$sync_state)"

    # Parse which scenarios to run
    local scenarios=("${@}")
    if [ ${#scenarios[@]} -eq 0 ]; then
        scenarios=(1 2 3 4 5 6 7 8)
    fi

    for s in "${scenarios[@]}"; do
        case "$s" in
            1) scenario1 ;;
            2) scenario2 ;;
            3) scenario3 ;;
            4) scenario4 ;;
            5) scenario5 ;;
            6) scenario6 ;;
            7) scenario7 ;;
            8) scenario8 ;;
            *) warn "Unknown scenario: $s" ;;
        esac
    done

    # Final summary
    hdr "OVERALL SUMMARY (scenarios ${scenarios[*]})"
    echo ""
    for S_NUM in "${scenarios[@]}"; do
        for MODE in remote_write remote_apply; do
            local f="$RESULTS_DIR/s${S_NUM}_${MODE}.log"
            if [ -f "$f" ]; then
                local lat tps
                lat=$(extract_avg_latency "$f")
                tps=$(extract_tps "$f")
                printf "  S%d %-14s  lat=%8s ms  tps=%8s\n" "$S_NUM" "$MODE" "$lat" "$tps"
            fi
        done
        echo ""
    done

    echo -e "${BOLD}See per-5s progress lines in $RESULTS_DIR/ for latency spikes.${NC}"
    echo ""
    log "Done."
}

trap 'echo ""; warn "Interrupted."; kill_standby_sessions 2>/dev/null; exit 130' INT

main "$@"
