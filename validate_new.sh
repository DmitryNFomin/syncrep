#!/usr/bin/env bash
# validate_new.sh — Run scenarios 4-8 on the existing Docker cluster.
#
# Usage:  bash validate_new.sh          # run all 5 scenarios
#         bash validate_new.sh 4 6      # run only scenarios 4 and 6
#
# Prereq: Docker containers must be running (run validate.sh first, or
#         docker compose -f docker/docker-compose.yml up -d)
set -euo pipefail

# Re-exec with line-buffered stdout so progress is visible in background mode
if [ "${UNBUFFERED:-}" != "1" ]; then
    export UNBUFFERED=1
    exec stdbuf -oL bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"

DOCKER=docker
if ! $DOCKER info >/dev/null 2>&1; then
    DOCKER="sudo docker"
fi
COMPOSE="$DOCKER compose -f $SCRIPT_DIR/docker/docker-compose.yml"

P="$DOCKER exec syncrep-primary"
S="$DOCKER exec syncrep-standby"
PSQL_P="$P psql -U postgres -d bench -v ON_ERROR_STOP=1"
PSQL_S="$S psql -U postgres -d bench -v ON_ERROR_STOP=1"

# Durations (seconds)
PROBE_DUR_S4=30     # Migration (UPDATE 2M + indexes) takes ~20s
PROBE_DUR_S5=60     # Bulk load of 2M rows takes ~47s
PROBE_DUR_S6=60     # FPI storm (direct, no background op)
PROBE_DUR_S7=60     # Reporting conflict
PROBE_DUR_S8=45     # VACUUM FULL + CLUSTER + REINDEX (~35s)

BLOCKER_SLEEP_S7=70
BLOCKER_SLEEP_S8=60

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
wait_for_primary() {
    for _ in $(seq 1 60); do
        $P pg_isready -U postgres -q 2>/dev/null && return 0
        sleep 1
    done
    err "Primary did not become ready"; exit 1
}

wait_for_standby() {
    for _ in $(seq 1 90); do
        $S pg_isready -U postgres -q 2>/dev/null && return 0
        sleep 1
    done
    err "Standby did not become ready"; exit 1
}

wait_for_sync_rep() {
    log "Waiting for synchronous replication..."
    for _ in $(seq 1 60); do
        local st
        st=$($PSQL_P -tAc \
            "SELECT sync_state FROM pg_stat_replication LIMIT 1;" 2>/dev/null || echo "")
        if [ "$st" = "sync" ] || [ "$st" = "quorum" ]; then
            log "Replication established (sync_state=$st)"
            return 0
        fi
        sleep 1
    done
    err "Replication not established"; exit 1
}

wait_for_catchup() {
    log "Waiting for replay to catch up..."
    local max_wait=${1:-120}
    for _ in $(seq 1 "$max_wait"); do
        local lag
        lag=$($PSQL_P -tAc "
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
    $PSQL_P -c "ALTER SYSTEM SET synchronous_commit = '$1';" >/dev/null
    $PSQL_P -c "SELECT pg_reload_conf();" >/dev/null
    sleep 1
    log "synchronous_commit = $1"
}

show_repl() {
    echo "  ── pg_stat_replication ──"
    $PSQL_P -c "
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

# Use local commit for setup phases so they don't wait for constrained standby replay
setup_begin() {
    set_sync_mode "local"
}

setup_end() {
    # Restore remote_write — don't wait for catchup unless needed
    set_sync_mode "remote_write"
    sleep 3
}

setup_end_synced() {
    # Restore remote_write AND wait for standby to catch up
    # (needed when the test queries the standby)
    set_sync_mode "remote_write"
    wait_for_catchup
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
# SCENARIO 4: CREATE INDEX (migration)
# ══════════════════════════════════════════════════════════════════════════════
scenario4() {
    hdr "SCENARIO 4: Schema migration"
    echo "  Strategy: UPDATE 2M rows + CREATE INDEX while OLTP runs."
    echo "  The UPDATE generates a massive WAL burst (~1GB); standby's"
    echo "  single-threaded replay can't keep up → remote_apply commits stall."
    echo ""

    setup_begin
    log "Loading data (2M rows, no secondary indexes — takes ~30s)..."
    $PSQL_P -f /bench/scenario4_create_index/setup.sql >/dev/null 2>&1
    setup_end

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"
        $PSQL_P -c "CHECKPOINT;" >/dev/null
        sleep 2

        # Drop any leftover indexes / reset column
        $P bash -c "psql -U postgres -d bench -c \"
            SET synchronous_commit TO local;
            DROP INDEX IF EXISTS events_ts_user;
            DROP INDEX IF EXISTS events_svc_dur;
            DROP INDEX IF EXISTS events_payload_trgm;
        \"" >/dev/null 2>&1
        sleep 3

        log "Starting probe pgbench (8 clients, ${PROBE_DUR_S4}s)..."
        $P bash -c "pgbench -U postgres --no-vacuum bench \
            -f /bench/scenario4_create_index/workload_probe.sql \
            -c 8 -j 4 -T $PROBE_DUR_S4 -P 5 --progress-timestamp 2>&1" \
            > "$RESULTS_DIR/s4_${MODE}.log" 2>&1 &
        PGBENCH_PID=$!

        sleep 5   # short baseline

        log "Running migration (UPDATE + CREATE INDEX, sync_commit=local)..."
        local t0=$(date +%s)

        # Phase 1: bulk UPDATE — rewrites 2M rows, generates ~1GB WAL burst
        $P bash -c "psql -U postgres -d bench \
            -c 'SET synchronous_commit TO local' \
            -c 'SET maintenance_work_mem = \"256MB\"' \
            -c 'UPDATE events SET payload = upper(payload)'" 2>&1
        log "  UPDATE done ($(( $(date +%s) - t0 ))s elapsed)"

        # Phase 2: CREATE INDEX (additional WAL on top of the UPDATE WAL)
        $P bash -c "psql -U postgres -d bench -c 'SET synchronous_commit TO local' \
            -c 'CREATE INDEX events_ts_user ON events(ts, user_id)'" 2>&1
        log "  btree index done ($(( $(date +%s) - t0 ))s elapsed)"

        $P bash -c "psql -U postgres -d bench -c 'SET synchronous_commit TO local' \
            -c 'CREATE INDEX events_svc_dur ON events(service, duration_ms)'" 2>&1
        log "  all indexes done ($(( $(date +%s) - t0 ))s elapsed)"

        log "Migration done. Waiting for pgbench to finish..."
        wait $PGBENCH_PID || true

        show_repl
        echo ""

        # Reset for next mode: revert the UPDATE + drop indexes
        $P bash -c "psql -U postgres -d bench -c \"
            SET synchronous_commit TO local;
            DROP INDEX IF EXISTS events_ts_user;
            DROP INDEX IF EXISTS events_svc_dur;
            UPDATE events SET payload = lower(payload);
        \"" >/dev/null 2>&1
        wait_for_catchup 120
    done

    print_comparison "SCENARIO 4" "$RESULTS_DIR/s4_remote_write.log" \
                     "$RESULTS_DIR/s4_remote_apply.log" 1.3
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 5: Bulk INSERT into indexed table (ETL)
# ══════════════════════════════════════════════════════════════════════════════
scenario5() {
    hdr "SCENARIO 5: Bulk INSERT into indexed table (ETL)"
    echo "  Strategy: INSERT...SELECT 2M rows into table with 4 indexes"
    echo "  while OLTP probe runs. Bulk WAL floods replay."
    echo ""

    setup_begin
    log "Loading schema (empty indexed table + probe)..."
    $PSQL_P -f /bench/scenario5_bulk_load/setup.sql >/dev/null 2>&1
    setup_end

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"

        # Clear any data from previous run
        $P bash -c "psql -U postgres -d bench \
            -c 'SET synchronous_commit TO local' \
            -c 'TRUNCATE logs'" >/dev/null 2>&1
        wait_for_catchup
        $PSQL_P -c "CHECKPOINT;" >/dev/null
        sleep 2

        log "Starting probe pgbench (8 clients, ${PROBE_DUR_S5}s)..."
        $P bash -c "pgbench -U postgres --no-vacuum bench \
            -f /bench/scenario5_bulk_load/workload_probe.sql \
            -c 8 -j 4 -T $PROBE_DUR_S5 -P 5 --progress-timestamp 2>&1" \
            > "$RESULTS_DIR/s5_${MODE}.log" 2>&1 &
        PGBENCH_PID=$!

        sleep 2   # minimal baseline — bulk load should dominate the run

        log "Bulk loading 2M rows (sync_commit=local)..."
        local t0=$(date +%s)
        $P bash -c "psql -U postgres -d bench <<'EOSQL'
SET synchronous_commit TO local;
INSERT INTO logs (ts, level, service, message, trace_id)
SELECT
    now() - make_interval(days => (random() * 30)::int),
    (ARRAY['DEBUG','INFO','WARN','ERROR','FATAL'])[1+(random()*4)::int],
    (ARRAY['auth','billing','search','export','notify','gateway','worker','scheduler'])[1+(random()*7)::int],
    'Request processed: ' || md5(random()::text) || ' status=' || (200 + (random()*300)::int) || ' duration=' || (random()*1000)::int || 'ms ' || md5(random()::text),
    md5(random()::text)
FROM generate_series(1, 2000000);
EOSQL" 2>&1
        log "  Bulk load done on primary ($(( $(date +%s) - t0 ))s)"

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
# SCENARIO 6: FPI storm (frequent checkpoints + scattered writes)
# ══════════════════════════════════════════════════════════════════════════════
scenario6() {
    hdr "SCENARIO 6: FPI storm (frequent checkpoints)"
    echo "  Strategy: checkpoint_timeout=30s + random scattered UPDATEs."
    echo "  After each checkpoint, every page touch generates 8KB FPI."
    echo ""

    setup_begin
    log "Loading data (2M rows, wide table, fillfactor=50 — takes ~30s)..."
    $PSQL_P -f /bench/scenario6_fpi_storm/setup.sql >/dev/null 2>&1
    setup_end

    # Temporarily set short checkpoint interval
    log "Setting checkpoint_timeout = 30s..."
    $PSQL_P -c "ALTER SYSTEM SET checkpoint_timeout = '30s';" >/dev/null
    $PSQL_P -c "SELECT pg_reload_conf();" >/dev/null

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"
        $PSQL_P -c "CHECKPOINT;" >/dev/null
        sleep 2

        log "Running pgbench (24 clients, ${PROBE_DUR_S6}s)..."
        $P bash -c "pgbench -U postgres --no-vacuum bench \
            -f /bench/scenario6_fpi_storm/workload.sql \
            -c 24 -j 8 -T $PROBE_DUR_S6 -P 5 --progress-timestamp 2>&1" \
            | tee "$RESULTS_DIR/s6_${MODE}.log"

        show_repl
        echo ""
    done

    # Restore checkpoint timeout
    log "Restoring checkpoint_timeout = 15min..."
    $PSQL_P -c "ALTER SYSTEM SET checkpoint_timeout = '15min';" >/dev/null
    $PSQL_P -c "SELECT pg_reload_conf();" >/dev/null

    wait_for_catchup
    print_comparison "SCENARIO 6" "$RESULTS_DIR/s6_remote_write.log" \
                     "$RESULTS_DIR/s6_remote_apply.log" 1.3
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 7: Reporting query on standby blocks replay
# ══════════════════════════════════════════════════════════════════════════════
scenario7() {
    hdr "SCENARIO 7: Reporting query blocks replay"
    echo "  Strategy: standby analytics query on 'orders' table holds snapshot;"
    echo "  churn + VACUUM on primary creates conflicting prune WAL;"
    echo "  replay pauses → remote_apply commits to ANY table freeze completely."
    echo "  (Cross-table replay blocking: report on table A freezes writes to table B.)"
    echo ""

    setup_begin
    log "Loading orders (500K rows) + probe table..."
    $PSQL_P -f /bench/scenario2_blocked_conflict/setup.sql >/dev/null 2>&1
    $PSQL_P -f /bench/scenario7_reporting_conflict/setup_probe.sql >/dev/null 2>&1
    setup_end_synced   # standby needs both tables

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"

        # 1. Run churn on orders (creates dead tuples) — uses remote_write so
        #    standby replay may lag behind.
        set_sync_mode "remote_write"
        log "Running order churn (30s, 4 clients)..."
        $P bash -c "pgbench -U postgres --no-vacuum bench \
            -f /bench/scenario2_blocked_conflict/workload_churn.sql \
            -c 4 -j 4 -T 30 2>&1" | tail -1
        sleep 5

        # 2. Start analytics report on standby (holds snapshot via pg_sleep).
        log "Starting analytics query on standby (holds snapshot for ~${BLOCKER_SLEEP_S7}s)..."
        $S bash -c "psql -U postgres -d bench -f /bench/scenario2_blocked_conflict/standby_blocker.sql" &
        ANALYTICS_PID=$!
        sleep 3

        local active
        active=$($PSQL_S -tAc \
            "SELECT count(*) FROM pg_stat_activity
             WHERE query LIKE '%pg_sleep%' AND state='active';" 2>/dev/null || echo 0)
        log "Active analytics sessions on standby: $active"

        # 3. VACUUM orders — prune WAL conflicts with standby snapshot,
        #    blocking ALL replay (not just for orders table).
        set_sync_mode "$MODE"
        log "VACUUM orders (generates conflict WAL)..."
        $P bash -c "psql -U postgres -d bench \
            -c 'SET synchronous_commit TO local' \
            -c 'VACUUM orders'" 2>&1 | tail -1
        sleep 1
        show_repl

        # 4. Start probe pgbench on probe_s7 table (different table!)
        #    Under remote_apply, replay is blocked → probe commits freeze.
        log "Starting probe pgbench on probe_s7 (8 clients, ${PROBE_DUR_S7}s)..."
        $P bash -c "pgbench -U postgres --no-vacuum bench \
            -f /bench/scenario7_reporting_conflict/workload_probe.sql \
            -c 8 -j 4 -T $PROBE_DUR_S7 -P 5 --progress-timestamp 2>&1" \
            | tee "$RESULTS_DIR/s7_${MODE}.log"

        show_repl

        # 5. Cleanup
        kill_standby_sessions
        wait $ANALYTICS_PID 2>/dev/null || true
        sleep 5
        wait_for_catchup 120

        # Re-create dead tuples for next mode
        if [ "$MODE" = "remote_write" ]; then
            log "Re-creating order churn for next run..."
            set_sync_mode "remote_write"
            $P bash -c "pgbench -U postgres --no-vacuum bench \
                -f /bench/scenario2_blocked_conflict/workload_churn.sql \
                -c 4 -j 4 -T 20 2>&1" >/dev/null
            wait_for_catchup
            $PSQL_P -c "CHECKPOINT;" >/dev/null
            sleep 2
        fi
        echo ""
    done

    print_comparison "SCENARIO 7" "$RESULTS_DIR/s7_remote_write.log" \
                     "$RESULTS_DIR/s7_remote_apply.log" 5.0
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 8: Table rewrite (VACUUM FULL)
# ══════════════════════════════════════════════════════════════════════════════
scenario8() {
    hdr "SCENARIO 8: Table rewrite (VACUUM FULL + lock conflict)"
    echo "  Strategy: standby read query holds AccessShareLock on 'bloated' table;"
    echo "  VACUUM FULL acquires AccessExclusiveLock → WAL record conflicts with"
    echo "  standby lock → ALL replay blocks. Combined with ~700 MB of rewrite WAL,"
    echo "  remote_apply commits to ANY table freeze completely."
    echo "  (Lock conflict — different from S7's snapshot/prune conflict.)"
    echo ""

    setup_begin
    log "Loading data (3M rows, 50% deleted — takes ~60s)..."
    $PSQL_P -f /bench/scenario8_table_rewrite/setup.sql >/dev/null 2>&1
    setup_end_synced   # standby needs bloated table for the blocker

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        wait_for_catchup 60

        # Start standby blocker: holds AccessShareLock on bloated
        set_sync_mode "remote_write"
        log "Starting standby read query on bloated (holds lock for ~${BLOCKER_SLEEP_S8}s)..."
        $S bash -c "psql -U postgres -d bench -f /bench/scenario8_table_rewrite/standby_blocker.sql" &
        BLOCKER_PID=$!
        sleep 3

        local active
        active=$($PSQL_S -tAc \
            "SELECT count(*) FROM pg_stat_activity
             WHERE query LIKE '%pg_sleep%' AND state='active';" 2>/dev/null || echo 0)
        log "Active blocker sessions on standby: $active"

        # Switch to target mode
        set_sync_mode "$MODE"
        $PSQL_P -c "CHECKPOINT;" >/dev/null
        sleep 1

        log "Starting probe pgbench (8 clients, ${PROBE_DUR_S8}s)..."
        $P bash -c "pgbench -U postgres --no-vacuum bench \
            -f /bench/scenario8_table_rewrite/workload_probe.sql \
            -c 8 -j 4 -T $PROBE_DUR_S8 -P 5 --progress-timestamp 2>&1" \
            > "$RESULTS_DIR/s8_${MODE}.log" 2>&1 &
        PGBENCH_PID=$!

        sleep 2   # minimal baseline

        log "Running VACUUM FULL + CLUSTER + REINDEX (sync_commit=local)..."
        local t0=$(date +%s)
        $P bash -c "psql -U postgres -d bench \
            -c 'SET synchronous_commit TO local' \
            -c 'VACUUM FULL bloated'" 2>&1
        log "  VACUUM FULL done ($(( $(date +%s) - t0 ))s elapsed)"

        $P bash -c "psql -U postgres -d bench \
            -c 'SET synchronous_commit TO local' \
            -c 'CLUSTER bloated USING bloated_pkey'" 2>&1
        log "  CLUSTER done ($(( $(date +%s) - t0 ))s elapsed)"

        $P bash -c "psql -U postgres -d bench \
            -c 'SET synchronous_commit TO local' \
            -c 'REINDEX TABLE bloated'" 2>&1
        log "  REINDEX done ($(( $(date +%s) - t0 ))s elapsed)"

        log "Waiting for pgbench to finish..."
        wait $PGBENCH_PID || true

        show_repl

        # Cleanup
        kill_standby_sessions
        wait $BLOCKER_PID 2>/dev/null || true
        sleep 5
        wait_for_catchup 120
        echo ""

        # Re-create dead tuples for next mode
        if [ "$MODE" = "remote_write" ]; then
            log "Re-creating table bloat for next run (takes ~60s)..."
            $P bash -c "psql -U postgres -d bench <<'EOSQL'
SET synchronous_commit TO local;
-- Re-insert deleted rows
INSERT INTO bloated SELECT i, 'pending', repeat(md5(i::text), 10), repeat(md5(i::text), 5), now()
FROM generate_series(2, 3000000, 2) i
ON CONFLICT (id) DO NOTHING;
-- Delete them again to create bloat
DELETE FROM bloated WHERE id % 2 = 0;
EOSQL" >/dev/null 2>&1
            wait_for_catchup 120
            $PSQL_P -c "CHECKPOINT;" >/dev/null
            sleep 2
        fi
    done

    print_comparison "SCENARIO 8" "$RESULTS_DIR/s8_remote_write.log" \
                     "$RESULTS_DIR/s8_remote_apply.log" 2.0
}

# ── MAIN ─────────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$RESULTS_DIR"

    # Check containers are running
    if ! $P pg_isready -U postgres -q 2>/dev/null; then
        hdr "Starting Docker environment"
        $COMPOSE up -d
        wait_for_primary
        wait_for_standby
    else
        log "Docker containers already running."
    fi
    wait_for_sync_rep

    # Parse which scenarios to run (default: all)
    local scenarios=("${@}")
    if [ ${#scenarios[@]} -eq 0 ]; then
        scenarios=(4 5 6 7 8)
    fi

    for s in "${scenarios[@]}"; do
        case "$s" in
            4) scenario4 ;;
            5) scenario5 ;;
            6) scenario6 ;;
            7) scenario7 ;;
            8) scenario8 ;;
            *) warn "Unknown scenario: $s" ;;
        esac
    done

    # ── Final summary ──
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

    echo -e "${BOLD}See per-5s progress lines in results/ for latency spikes during operations.${NC}"
    echo ""
    log "Done. Containers still running."
}

trap 'echo ""; warn "Interrupted. Containers left running."; \
      kill_standby_sessions 2>/dev/null; exit 130' INT

main "$@"
