#!/usr/bin/env bash
# run.sh — Run syncrep benchmark scenarios on a Patroni-managed cluster
#
# Prerequisites:
#   source syncrep.conf && bash setup_patroni_env.sh   # once
#
# Usage:
#   source syncrep.conf && bash run.sh          # all scenarios 1-10
#   source syncrep.conf && bash run.sh 4 9 10   # specific scenarios
#
# Required env vars (set by sourcing syncrep.conf):
#   PRIMARY_HOST  STANDBY_HOST  PGUSER  PGDATABASE  SQL_DIR  RESULTS_DIR
#   PRIMARY_PORT  STANDBY_PORT  PGPASSWORD (optional)

set -euo pipefail

# Auto-source syncrep.conf from the script's own directory when the required
# env vars are not already in the environment.  This lets you run directly:
#   bash run.sh          (syncrep.conf must be in the same directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${PRIMARY_HOST:-}" && -f "$SCRIPT_DIR/syncrep.conf" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/syncrep.conf"
fi

: "${PRIMARY_HOST:?syncrep.conf not found or PRIMARY_HOST not set}"
: "${STANDBY_HOST:?syncrep.conf not found or STANDBY_HOST not set}"
: "${PGUSER:?syncrep.conf not found or PGUSER not set}"
: "${PGDATABASE:?syncrep.conf not found or PGDATABASE not set}"
: "${SQL_DIR:?syncrep.conf not found or SQL_DIR not set}"
: "${RESULTS_DIR:?syncrep.conf not found or RESULTS_DIR not set}"

export PGPASSWORD="${PGPASSWORD:-}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
STANDBY_PORT="${STANDBY_PORT:-5432}"

mkdir -p "$RESULTS_DIR"

# ── connection helpers ────────────────────────────────────────────────────────
PSQL="psql -h $PRIMARY_HOST -p $PRIMARY_PORT -U $PGUSER -d $PGDATABASE -v ON_ERROR_STOP=1"
PSQL_S="psql -h $STANDBY_HOST -p $STANDBY_PORT -U $PGUSER -d $PGDATABASE"
PGBENCH="pgbench -h $PRIMARY_HOST -p $PRIMARY_PORT -U $PGUSER --no-vacuum $PGDATABASE"
PGBENCH_S="pgbench -h $STANDBY_HOST -p $STANDBY_PORT -U $PGUSER --no-vacuum $PGDATABASE"

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}>>>${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
err()  { echo -e "${RED}ERROR:${NC} $*"; }
hdr()  { echo -e "\n${BOLD}${CYAN}════════════════════════════════════════${NC}"; \
         echo -e "${BOLD}${CYAN}  $*${NC}"; \
         echo -e "${BOLD}${CYAN}════════════════════════════════════════${NC}"; }

# ── helpers ───────────────────────────────────────────────────────────────────
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
    warn "Replay did not fully catch up (lag=${lag:-?} bytes) — continuing anyway"
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

# Time-weighted average latency from pgbench progress lines.
# Unlike pgbench's "latency average" (transaction-weighted), this treats
# each 5s interval equally — essential for bursty scenarios where a few
# seconds at 400ms are drowned by millions of fast transactions.
extract_time_weighted_latency() {
    grep '^progress:' "$1" 2>/dev/null \
        | awk -F', ' '{for(i=1;i<=NF;i++) if($i ~ /^lat /) {split($i,a," "); print a[2]}}' \
        | awk '{s+=$1; n++} END {if(n>0) printf "%.1f", s/n; else print ""}'
}

# Peak 5-second-window latency from pgbench progress lines.
extract_peak_latency() {
    grep '^progress:' "$1" 2>/dev/null \
        | awk -F', ' '{for(i=1;i<=NF;i++) if($i ~ /^lat /) {split($i,a," "); print a[2]}}' \
        | awk 'BEGIN{m=0} {if($1>m) m=$1} END {if(m>0) printf "%.1f", m; else print ""}'
}

extract_tps() {
    grep '^tps' "$1" 2>/dev/null | head -1 | awk -F'= ' '{print $2}' | awk '{print $1}'
}

# Count 0-TPS intervals from pgbench progress output.
# When remote_apply blocks replay, ALL clients freeze: pgbench reports 0.0 TPS
# for those intervals. This detects the complete freeze, not just "high latency".
# Args: $1 = log file (must contain pgbench -P progress lines via 2>&1)
# Output: "zero_intervals total_intervals"
parse_blocking_stats() {
    local file="$1"
    local zero total
    zero=$(grep -c ', 0\.0 tps,' "$file" 2>/dev/null) || zero=0
    total=$(grep -c '^progress:' "$file" 2>/dev/null) || total=0
    echo "$zero $total"
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
        local added ratio
        added=$(awk "BEGIN {printf \"%.1f\", $lat_ra - $lat_rw}")
        ratio=$(awk "BEGIN {printf \"%.1f\", $lat_ra / $lat_rw}")
        echo ""
        echo -e "  ${BOLD}Added latency (apply − write): +${added} ms${NC}"
        echo -e "  Latency ratio: ${ratio}x"
        if awk "BEGIN {exit !($lat_ra > $lat_rw * $pass_threshold)}"; then
            echo -e "  ${GREEN}PASS${NC} — remote_apply latency is measurably higher"
        else
            echo -e "  ${YELLOW}MARGINAL${NC} — delta is small"
        fi
    fi
    echo ""
}

# Print results for blocking scenarios (S2, S7, S8).
# These scenarios cause a COMPLETE FREEZE of all commits under remote_apply,
# not just increased latency. Average latency is misleading because pgbench
# only counts completed transactions — it hides the 60-80s total outage.
print_blocking_comparison() {
    local label="$1" rw_log="$2" ra_log="$3"

    local tps_rw tps_ra
    tps_rw=$(extract_tps "$rw_log")
    tps_ra=$(extract_tps "$ra_log")

    # Count 0-TPS intervals from remote_apply progress output (5s intervals)
    local zero_int total_int
    read -r zero_int total_int <<< "$(parse_blocking_stats "$ra_log")"
    local blocked_s=$(( zero_int * 5 ))
    local total_s=$(( total_int * 5 ))

    hdr "$label — RESULTS"
    printf "  %-20s %12s %12s\n" ""    "remote_write" "remote_apply"
    printf "  %-20s %12s %12s\n" "TPS" "$tps_rw"      "$tps_ra"
    echo ""

    if [ "$zero_int" -gt 0 ]; then
        echo -e "  ${RED}${BOLD}BLOCKED${NC} — remote_apply: 0 TPS for ${blocked_s}s out of ${total_s}s"
        echo -e "  All commits were completely frozen while replay was paused."
        if [ -n "$tps_rw" ] && [ -n "$tps_ra" ]; then
            local tps_ratio
            tps_ratio=$(awk "BEGIN {printf \"%.0f\", $tps_rw / $tps_ra}")
            echo -e "  Effective TPS drop: ${tps_ratio}x"
        fi
    else
        # Fallback: no blocking detected (e.g. progress lines not captured)
        local lat_rw lat_ra
        lat_rw=$(extract_avg_latency "$rw_log")
        lat_ra=$(extract_avg_latency "$ra_log")
        printf "  %-20s %12s %12s\n" "avg latency (ms)" "$lat_rw" "$lat_ra"
        if [ -n "$lat_rw" ] && [ -n "$lat_ra" ]; then
            local added ratio
            added=$(awk "BEGIN {printf \"%.1f\", $lat_ra - $lat_rw}")
            ratio=$(awk "BEGIN {printf \"%.1f\", $lat_ra / $lat_rw}")
            echo -e "  ${BOLD}Added latency: +${added} ms${NC}  (ratio: ${ratio}x)"
        fi
    fi
    echo ""
}

# Print results for burst scenarios (S4) where a brief heavy WAL phase
# is followed by calm.  pgbench's transaction-weighted average hides
# the spike (370 slow txns drowned by 260K fast ones).  Instead report:
#   - Time-weighted average (mean of per-interval latencies)
#   - Peak 5s-window latency
#   - TPS ratio
print_burst_comparison() {
    local label="$1" rw_log="$2" ra_log="$3"

    local tw_rw tw_ra pk_rw pk_ra tps_rw tps_ra
    tw_rw=$(extract_time_weighted_latency "$rw_log")
    tw_ra=$(extract_time_weighted_latency "$ra_log")
    pk_rw=$(extract_peak_latency "$rw_log")
    pk_ra=$(extract_peak_latency "$ra_log")
    tps_rw=$(extract_tps "$rw_log")
    tps_ra=$(extract_tps "$ra_log")

    hdr "$label — RESULTS"
    printf "  %-28s %12s %12s\n" ""                        "remote_write" "remote_apply"
    printf "  %-28s %12s %12s\n" "time-weighted avg (ms)"  "$tw_rw"       "$tw_ra"
    printf "  %-28s %12s %12s\n" "peak 5s-window (ms)"     "$pk_rw"       "$pk_ra"
    printf "  %-28s %12s %12s\n" "TPS"                     "$tps_rw"      "$tps_ra"

    if [ -n "$tw_rw" ] && [ -n "$tw_ra" ]; then
        local added ratio
        added=$(awk "BEGIN {printf \"%.1f\", $tw_ra - $tw_rw}")
        ratio=$(awk "BEGIN {printf \"%.1f\", $tw_ra / $tw_rw}")
        echo ""
        echo -e "  ${BOLD}Added latency (time-weighted): +${added} ms${NC}"
        echo -e "  Latency ratio: ${ratio}x"
        if [ -n "$pk_rw" ] && [ -n "$pk_ra" ]; then
            local pk_added
            pk_added=$(awk "BEGIN {printf \"%.1f\", $pk_ra - $pk_rw}")
            echo -e "  Peak-window delta: +${pk_added} ms"
        fi
    fi
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 1: Index-heavy UPDATE saturation
# ══════════════════════════════════════════════════════════════════════════════
scenario1() {
    hdr "SCENARIO 1: Index-heavy batch UPDATE saturation"
    echo "  Strategy: 32 clients UPDATE 100 SCATTERED rows per commit, 15 indexes."
    echo "  Scattered = each row on a different heap page + different index leaf pages."
    echo "  Each commit → ~1600 distinct page modifications replayed serially."
    echo "  32 clients generating heavy WAL concurrently → replay backlog builds."
    echo ""

    set_sync_mode "local"
    log "Loading data (2M rows, 15 indexes — takes ~60s)..."
    $PSQL -f $SQL_DIR/scenario1_saturate_indexes/setup.sql >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup 300

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"
        $PSQL -c "CHECKPOINT;" >/dev/null
        sleep 2

        log "Running pgbench (32 clients, 45s)..."
        $PGBENCH \
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

        set_sync_mode "remote_write"
        log "Running order churn (30s, 4 clients)..."
        $PGBENCH \
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

        log "Starting probe pgbench (8 clients, 30s)..."
        $PGBENCH \
            -f $SQL_DIR/scenario2_blocked_conflict/workload_steady.sql \
            -c 8 -j 4 -T 30 -P 5 --progress-timestamp 2>&1 \
            | tee "$RESULTS_DIR/s2_${MODE}.log"

        show_repl
        kill_standby_sessions
        wait $ANALYTICS_PID 2>/dev/null || true
        sleep 5
        wait_for_catchup 120

        if [ "$MODE" = "remote_write" ]; then
            log "Re-creating order churn for next run..."
            set_sync_mode "remote_write"
            $PGBENCH \
                -f $SQL_DIR/scenario2_blocked_conflict/workload_churn.sql \
                -c 4 -j 4 -T 20 2>&1 >/dev/null
            wait_for_catchup
            $PSQL -c "CHECKPOINT;" >/dev/null
            sleep 2
        fi
        echo ""
    done

    print_blocking_comparison "SCENARIO 2" "$RESULTS_DIR/s2_remote_write.log" \
                              "$RESULTS_DIR/s2_remote_apply.log"
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 3: GIN + TOAST bursty replay
# ══════════════════════════════════════════════════════════════════════════════
scenario3() {
    hdr "SCENARIO 3: GIN + TOAST bursty replay"
    echo "  Strategy: 70% INSERT / 30% UPDATE, 30 rows per commit,"
    echo "  with large TOAST bodies and 4 GIN indexes (gin_pending_list_limit=64)."
    echo "  UPDATE rows are scattered across the table (spaced 10K apart) to"
    echo "  maximize distinct page modifications per commit."
    echo "  GIN pending-list flushes are CPU-intensive (posting tree traversal,"
    echo "  compression) — faster NVMe doesn't help, replay is CPU-bound."
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

        log "Running mixed workload (24 clients, 45s)..."
        $PGBENCH \
            -f $SQL_DIR/scenario3_gin_toast/workload_insert.sql@7 \
            -f $SQL_DIR/scenario3_gin_toast/workload_update.sql@3 \
            -c 24 -j 8 -T 45 -P 5 --progress-timestamp 2>&1 \
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
    hdr "SCENARIO 4: Schema migration (parallel UPDATE + CREATE INDEX)"
    echo "  Strategy: 4 concurrent UPDATEs of 500K rows each (touching indexed"
    echo "  columns) + 2 CREATE INDEX — all with synchronous_commit=local."
    echo "  The initial CHECKPOINT causes full-page images (8 KB each) for every"
    echo "  page modified — creating a brief but massive WAL burst (~500 MB in"
    echo "  ~10s) that overwhelms single-threaded replay."
    echo "  A short 25s probe captures this burst with minimal dilution."
    echo ""

    set_sync_mode "local"
    log "Loading data (2M rows + 4 indexes — takes ~60s)..."
    $PSQL -f $SQL_DIR/scenario4_create_index/setup.sql >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"
        $PSQL -c "CHECKPOINT;" >/dev/null
        sleep 2

        $PSQL -c "SET synchronous_commit TO local" \
              -c "DROP INDEX IF EXISTS events_ts_user" \
              -c "DROP INDEX IF EXISTS events_svc_dur" >/dev/null 2>&1
        sleep 3

        log "Running parallel migration (4× UPDATE + 2× CREATE INDEX, local sync)..."
        local t0=$(date +%s)

        # 4 parallel UPDATEs, each handling 500K rows.
        # After CHECKPOINT, the first modification to each page generates
        # an 8 KB full-page image (FPI).  This creates a massive WAL burst
        # in the first ~10-15s that overwhelms single-threaded replay.
        local -a UPDATE_PIDS=()
        for PART in 1 2 3 4; do
            local start_id=$(( (PART - 1) * 500000 + 1 ))
            local end_id=$(( PART * 500000 ))
            $PSQL -c "SET synchronous_commit TO local" \
                  -c "SET maintenance_work_mem = '256MB'" \
                  -c "UPDATE events SET user_id = user_id + 1, duration_ms = duration_ms + 1, payload = upper(payload) WHERE id BETWEEN $start_id AND $end_id" \
                  >/dev/null 2>&1 &
            UPDATE_PIDS+=($!)
        done

        # Start probe SIMULTANEOUSLY with migration — 25s captures
        # the FPI burst with minimal dilution from post-burst calm.
        sleep 2  # let UPDATEs ramp up WAL generation
        log "Starting probe pgbench (16 clients, 25s)..."
        $PGBENCH \
            -f $SQL_DIR/scenario4_create_index/workload_probe.sql \
            -c 16 -j 8 -T 25 -P 5 --progress-timestamp 2>&1 \
            | tee "$RESULTS_DIR/s4_${MODE}.log" &
        PGBENCH_PID=$!

        for pid in "${UPDATE_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
        log "  parallel UPDATE done ($(( $(date +%s) - t0 ))s elapsed)"

        $PSQL -c "SET synchronous_commit TO local" \
              -c "CREATE INDEX events_ts_user ON events(ts, user_id)" 2>&1
        log "  btree index #1 done ($(( $(date +%s) - t0 ))s elapsed)"

        $PSQL -c "SET synchronous_commit TO local" \
              -c "CREATE INDEX events_svc_dur ON events(service, duration_ms)" 2>&1
        log "  btree index #2 done ($(( $(date +%s) - t0 ))s elapsed)"

        log "Migration done. Waiting for pgbench to finish..."
        wait $PGBENCH_PID || true

        show_repl
        echo ""

        # Reverse changes for next iteration
        set_sync_mode "local"
        $PSQL -c "DROP INDEX IF EXISTS events_ts_user" \
              -c "DROP INDEX IF EXISTS events_svc_dur" >/dev/null 2>&1
        for PART in 1 2 3 4; do
            local start_id=$(( (PART - 1) * 500000 + 1 ))
            local end_id=$(( PART * 500000 ))
            $PSQL -c "UPDATE events SET user_id = user_id - 1, duration_ms = duration_ms - 1, payload = lower(payload) WHERE id BETWEEN $start_id AND $end_id" \
                  >/dev/null 2>&1 &
        done
        wait
        set_sync_mode "remote_write"
        wait_for_catchup 300
    done

    print_burst_comparison "SCENARIO 4" "$RESULTS_DIR/s4_remote_write.log" \
                          "$RESULTS_DIR/s4_remote_apply.log"
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

        $PSQL -c "SET synchronous_commit TO local" \
              -c "TRUNCATE logs" >/dev/null 2>&1
        wait_for_catchup
        $PSQL -c "CHECKPOINT;" >/dev/null
        sleep 2

        log "Starting probe pgbench (8 clients, 60s)..."
        $PGBENCH \
            -f $SQL_DIR/scenario5_bulk_load/workload_probe.sql \
            -c 8 -j 4 -T 60 -P 5 --progress-timestamp 2>&1 \
            > "$RESULTS_DIR/s5_${MODE}.log" &
        PGBENCH_PID=$!

        sleep 2

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
    echo "  NOTE: effect scales directly with shared_buffers size."
    echo "  On this server, shared_buffers may be small → marginal result."
    echo "  At shared_buffers=75 GB (typical on a 300 GiB server), a checkpoint"
    echo "  FPI storm can generate 10-75 GB of WAL in seconds. Replay at 300 MB/s"
    echo "  takes 30-250 seconds — all remote_apply commits stall for the duration."
    echo ""

    set_sync_mode "local"
    log "Loading data (2M rows, fillfactor=50 — takes ~30s)..."
    $PSQL -f $SQL_DIR/scenario6_fpi_storm/setup.sql >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup

    log "Setting checkpoint_timeout = 30s..."
    $PSQL -c "ALTER SYSTEM SET checkpoint_timeout = '30s';" >/dev/null
    $PSQL -c "SELECT pg_reload_conf();" >/dev/null

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"
        $PSQL -c "CHECKPOINT;" >/dev/null
        sleep 2

        log "Running pgbench (24 clients, 60s)..."
        $PGBENCH \
            -f $SQL_DIR/scenario6_fpi_storm/workload.sql \
            -c 24 -j 8 -T 60 -P 5 --progress-timestamp 2>&1 \
            | tee "$RESULTS_DIR/s6_${MODE}.log"

        show_repl
        wait_for_catchup
        echo ""
    done

    log "Restoring checkpoint_timeout = 15min..."
    $PSQL -c "ALTER SYSTEM SET checkpoint_timeout = '15min';" >/dev/null
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
        $PGBENCH \
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
        $PGBENCH \
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
            $PGBENCH \
                -f $SQL_DIR/scenario2_blocked_conflict/workload_churn.sql \
                -c 4 -j 4 -T 20 2>&1 >/dev/null
            wait_for_catchup
            $PSQL -c "CHECKPOINT;" >/dev/null
            sleep 2
        fi
        echo ""
    done

    print_blocking_comparison "SCENARIO 7" "$RESULTS_DIR/s7_remote_write.log" \
                              "$RESULTS_DIR/s7_remote_apply.log"
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
        $PGBENCH \
            -f $SQL_DIR/scenario8_table_rewrite/workload_probe.sql \
            -c 8 -j 4 -T 45 -P 5 --progress-timestamp 2>&1 \
            | tee "$RESULTS_DIR/s8_${MODE}.log" &
        PGBENCH_PID=$!

        sleep 2

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

    print_blocking_comparison "SCENARIO 8" "$RESULTS_DIR/s8_remote_write.log" \
                              "$RESULTS_DIR/s8_remote_apply.log"
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 9: Buffer pin contention during VACUUM FREEZE replay
# ══════════════════════════════════════════════════════════════════════════════
# NOT IN DEFAULTS: FREEZE_PAGE replay uses XLogReadBufferForRedo (regular
# exclusive lock), NOT LockBufferForCleanup. Buffer pins from concurrent
# scanners do not block it. Only HEAP2_PRUNE and BTREE_VACUUM records need
# cleanup locks, but hot_standby_feedback prevents their generation.
# Run manually:  bash run.sh 9
scenario9() {
    hdr "SCENARIO 9: Buffer pin contention BLOCKS VACUUM FREEZE replay"
    echo "  Mechanism: XLOG_HEAP2_FREEZE_PAGE replay calls"
    echo "  LockBufferForCleanup() which requires pin count = 1."
    echo "  With max_standby_streaming_delay=-1, the startup process waits"
    echo "  indefinitely for ALL pins to drop before acquiring cleanup lock."
    echo ""
    echo "  80 concurrent scans on a tiny table (~20 pages) create a"
    echo "  livelock: 4 expected pins per page means the startup process"
    echo "  can never find a zero-pin window long enough to acquire the lock."
    echo "  Result: replay is completely blocked for the scan duration."
    echo ""
    echo "  This is a BLOCKING scenario (like S2/S7/S8) but with a different"
    echo "  mechanism: no long-running queries or old snapshots needed —"
    echo "  just normal sequential scan traffic on the standby."
    echo ""

    set_sync_mode "local"
    log "Loading freeze_test (100 wide rows, ~20 pages)..."
    $PSQL -f $SQL_DIR/scenario9_buffer_pin/setup.sql >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup 120

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"

        # CHECKPOINT forces FPIs for all pages on the next VACUUM FREEZE,
        # amplifying WAL volume (~8 MB of FPIs for a ~8 MB table).
        log "CHECKPOINT to force FPIs on next VACUUM FREEZE..."
        $PSQL -c "CHECKPOINT;" >/dev/null
        sleep 2

        # UPDATE 1/3 of rows with local sync so VACUUM FREEZE has work to do
        # (already-frozen tuples are skipped; we need unfrozen ones).
        log "Updating 1/3 of rows to create unfrozen tuples (local sync)..."
        $PSQL -c "SET synchronous_commit TO local;
                  UPDATE freeze_test SET b = repeat(chr(65 + (id % 26)::int), 500)
                  WHERE id % 3 = 0;" >/dev/null

        # Start 80 parallel full-table scans on standby to create pin pressure.
        # 80 scanners on ~20 pages = 4 expected pins per page.
        # Zero-pin windows are ~0.5μs — too brief for the startup process
        # to wake (~5μs) and acquire the cleanup lock. True livelock.
        log "Starting 80 parallel full-table scans on standby (pin livelock)..."
        $PGBENCH_S \
            -f $SQL_DIR/scenario9_buffer_pin/standby_scanner.sql \
            -c 80 -j 8 -T 75 --no-vacuum 2>/dev/null &
        SCANNER_PID=$!
        sleep 3  # let scanners get going

        # Run VACUUM FREEZE loop in background with local sync.
        # Each VACUUM FREEZE generates FREEZE_PAGE WAL for every unfrozen page;
        # replay must acquire a buffer cleanup lock per page → pin conflicts.
        # We cycle UPDATE→VACUUM FREEZE to keep generating work.
        log "Starting VACUUM FREEZE loop (local sync)..."
        (
            for i in $(seq 1 12); do
                $PSQL -c "SET synchronous_commit TO local;
                          UPDATE freeze_test SET b = repeat(chr(65 + (id % 26)::int), 500)
                          WHERE id % 5 = 0;" \
                      >/dev/null 2>&1
                $PSQL -c "SET vacuum_freeze_min_age = 0;
                          SET synchronous_commit TO local;
                          VACUUM FREEZE freeze_test;" \
                      >/dev/null 2>&1
                sleep 1
            done
        ) &
        FREEZE_PID=$!

        sleep 5  # let first freeze run and build replay backlog

        log "Running probe pgbench (8 clients, 45s)..."
        $PGBENCH \
            -f $SQL_DIR/scenario9_buffer_pin/workload.sql \
            -c 8 -j 4 -T 45 -P 5 --progress-timestamp 2>&1 \
            | tee "$RESULTS_DIR/s9_${MODE}.log"

        show_repl
        kill $SCANNER_PID 2>/dev/null; wait $SCANNER_PID 2>/dev/null || true
        wait $FREEZE_PID 2>/dev/null || true
        wait_for_catchup 300
        echo ""
    done

    print_blocking_comparison "SCENARIO 9" "$RESULTS_DIR/s9_remote_write.log" \
                              "$RESULTS_DIR/s9_remote_apply.log"
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 10: Large synchronous UPDATE — I/O-heavy replay
# ══════════════════════════════════════════════════════════════════════════════
scenario10() {
    hdr "SCENARIO 10: Large synchronous UPDATE — I/O-heavy replay"
    echo "  Mechanism (answer to 'why ≈ 2×'):"
    echo "    remote_write commit wait ≈ network RTT for the commit WAL record."
    echo "    The UPDATE's WAL has already streamed to the standby during"
    echo "    execution, so remote_write only pays for the last few KB."
    echo ""
    echo "    remote_apply commit wait = time for standby to replay ALL of the"
    echo "    transaction's WAL — single-threaded, I/O-bound, walks every index."
    echo "    With replay_time ≈ execution_time, ratio ≈ 2×."
    echo "    With a memory-constrained standby (more cache misses), ratio > 2×."
    echo ""
    echo "  Part A: pgbench, 4 clients, 50K-row batch UPDATEs, 4 secondary indexes."
    echo "  Part B: single full-table UPDATE (1M rows), wall-clock timed directly."
    echo ""

    set_sync_mode "local"
    log "Loading big_updates (1M rows, 4 indexes — takes ~60s)..."
    $PSQL -f $SQL_DIR/scenario10_large_sync_update/setup.sql >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup 300

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"
        $PSQL -c "CHECKPOINT;" >/dev/null
        sleep 2

        # Part A: sustained batch UPDATE workload measured by pgbench
        log "Part A: batch UPDATE pgbench (4 clients, 60s)..."
        $PGBENCH \
            -f $SQL_DIR/scenario10_large_sync_update/workload_batch.sql \
            -c 4 -j 4 -T 60 -P 5 --progress-timestamp 2>&1 \
            | tee "$RESULTS_DIR/s10_${MODE}.log"

        show_repl
        wait_for_catchup 300

        # Part B: single full-table UPDATE, wall-clock measured
        log "Part B: single full-table UPDATE (1M rows, all 4 indexes)..."
        set_sync_mode "$MODE"
        local t0_ms
        t0_ms=$(date +%s%3N)
        $PSQL -c "UPDATE big_updates SET a = a + 1, b = b + 1, ts = now();" >/dev/null
        local elapsed_ms=$(( $(date +%s%3N) - t0_ms ))

        echo ""
        echo "  full-table UPDATE wall time (${MODE}): ${elapsed_ms} ms" \
            | tee -a "$RESULTS_DIR/s10_${MODE}.log"

        show_repl
        wait_for_catchup 300
        echo ""
    done

    print_comparison "SCENARIO 10 (Part A)" \
        "$RESULTS_DIR/s10_remote_write.log" \
        "$RESULTS_DIR/s10_remote_apply.log" 1.5

    echo "  --- Part B: single full-table UPDATE wall time ---"
    for MODE in remote_write remote_apply; do
        local t
        t=$(grep "full-table UPDATE wall time" "$RESULTS_DIR/s10_${MODE}.log" \
            | awk '{print $(NF-1), $NF}')
        printf "  %-15s: %s\n" "$MODE" "$t"
    done
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 11: DROP TABLE of partitioned table — XLogFlush + mass file unlinks
# ══════════════════════════════════════════════════════════════════════════════
scenario11() {
    hdr "SCENARIO 11: DROP TABLE of 50-partition table — mass file unlinks in commit replay"
    echo "  Source: xact.c:6236-6239, xact_redo_commit()"
    echo "  When a commit WAL record includes dropped relations (nrels > 0),"
    echo "  the startup process does BEFORE returning from that record:"
    echo "    1. XLogFlush(lsn)     — synchronous WAL fsync to advance minRecoveryPoint"
    echo "    2. DropRelationFiles() — durable_unlink() per fork × per relation"
    echo "  50 partitions × (heap+FSM+VM) + 50 PKs × (main+FSM) + 50 TOAST × 3 forks"
    echo "  + 50 TOAST indexes × 2 ≈ 500 synchronous file unlinks in one commit replay."
    echo ""
    echo "  remote_write: commit instant after DROP finishes on primary."
    echo "  remote_apply: waits for XLogFlush + ~500 durable_unlink() syscalls."
    echo ""
    echo "  SCALE: unlink count ≈ partitions × (heap+FSM+VM+index forks)."
    echo "  10,000 partitions → ~100,000 unlinks. At ~0.1 ms each on a loaded"
    echo "  filesystem: 10+ seconds of remote_apply stall per DROP."
    echo ""

    # Wall-clock timing for this scenario (not pgbench)
    for MODE in remote_write remote_apply; do
        log "── $MODE ──"

        # Recreate the partitioned table (it was dropped in the previous pass
        # or doesn't exist yet for the first pass).
        set_sync_mode "local"
        log "Creating 50-partition table (local sync — takes ~60s first time)..."
        $PSQL -f $SQL_DIR/scenario11_drop_partitions/setup.sql >/dev/null 2>&1
        set_sync_mode "remote_write"
        wait_for_catchup 180

        set_sync_mode "$MODE"
        $PSQL -c "CHECKPOINT;" >/dev/null
        sleep 2

        log "Timing DROP TABLE CASCADE (50 partitions + all dependent objects)..."
        local t0_ms
        t0_ms=$(date +%s%3N)
        $PSQL -c "DROP TABLE part_test CASCADE;" >/dev/null
        local elapsed_ms=$(( $(date +%s%3N) - t0_ms ))

        echo ""
        echo "  DROP TABLE wall time (${MODE}): ${elapsed_ms} ms" | tee "$RESULTS_DIR/s11_${MODE}.log"
        show_repl
        wait_for_catchup 60
        echo ""
    done

    hdr "SCENARIO 11 — RESULTS"
    echo "  Wall-clock includes DROP execution + commit wait."
    echo "  The remote_apply overhead ≈ XLogFlush + ~500 × durable_unlink()."
    echo ""
    for MODE in remote_write remote_apply; do
        local t
        t=$(grep "DROP TABLE wall time" "$RESULTS_DIR/s11_${MODE}.log" | awk '{print $(NF-1), $NF}')
        printf "  %-15s: %s\n" "$MODE" "$t"
    done
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 12: VACUUM FULL + logical slot — pg_fsync per rewrite mapping record
# ══════════════════════════════════════════════════════════════════════════════
scenario12() {
    hdr "SCENARIO 12: VACUUM FULL + logical slot — pg_fsync() per rewrite record"
    echo "  Source: rewriteheap.c:1132, heap_xlog_logical_rewrite()"
    echo "  PREREQUISITE: wal_level = logical + an active logical replication slot."
    echo ""
    echo "  When wal_level=logical and a logical slot exists, VACUUM FULL/CLUSTER"
    echo "  write XLOG_HEAP2_REWRITE records (old→new TID mappings for logical"
    echo "  decoding).  During replay, heap_xlog_logical_rewrite() calls:"
    echo "    pg_fsync(fd)  ← every single record, not just at end"
    echo "  For a 300K-row table: ~300 records → ~300 fsyncs during replay."
    echo ""
    echo "  Without a logical slot: no XLOG_HEAP2_REWRITE records are written;"
    echo "  VACUUM FULL commits at the same speed under both modes."
    echo "  With a logical slot: remote_apply must absorb N fsyncs of pure overhead."
    echo ""
    echo "  SCALE: fsyncs ≈ rows / rows_per_page. A 100M-row table generates"
    echo "  ~100,000 fsyncs during replay — seconds to minutes of stall per"
    echo "  VACUUM FULL when a logical slot exists."
    echo ""

    # Check prerequisite
    local wl
    wl=$($PSQL -tAc "SHOW wal_level;" 2>/dev/null || echo "unknown")
    if [ "$wl" != "logical" ]; then
        warn "Skipping S12: wal_level='${wl}' (need 'logical')."
        warn "Set wal_level=logical in postgresql.conf and restart PostgreSQL."
        return 0
    fi

    set_sync_mode "local"
    log "Loading rewrite_test (300K rows + logical slot — takes ~20s)..."
    $PSQL -f $SQL_DIR/scenario12_logical_rewrite/setup.sql >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup 120

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"

        # Bloat the table: update all rows to double the live-tuple count.
        # VACUUM FULL rewrites from ~200 MB (bloated) to ~100 MB (clean),
        # generating all the XLOG_HEAP2_REWRITE records.
        set_sync_mode "local"
        log "Bloating rewrite_test (UPDATE all rows, local sync — ~20s)..."
        $PSQL -c "SET synchronous_commit TO local;
                  UPDATE rewrite_test SET val = md5(val);" >/dev/null
        wait_for_catchup 120

        set_sync_mode "$MODE"
        $PSQL -c "CHECKPOINT;" >/dev/null
        sleep 2

        log "Timing VACUUM FULL (generates XLOG_HEAP2_REWRITE records)..."
        local t0_ms
        t0_ms=$(date +%s%3N)
        $PSQL -c "VACUUM FULL rewrite_test;" >/dev/null
        local elapsed_ms=$(( $(date +%s%3N) - t0_ms ))

        echo ""
        echo "  VACUUM FULL wall time (${MODE}): ${elapsed_ms} ms" | tee "$RESULTS_DIR/s12_${MODE}.log"
        show_repl
        wait_for_catchup 180
        echo ""
    done

    # Drop the logical slot so it doesn't accumulate WAL on subsequent runs
    $PSQL -c "SELECT pg_drop_replication_slot('syncrep_bench_slot');" \
          >/dev/null 2>&1 || true

    hdr "SCENARIO 12 — RESULTS"
    echo "  Wall-clock includes VACUUM FULL execution + commit wait."
    echo "  remote_apply overhead ≈ N × pg_fsync() on rewrite mapping files."
    echo ""
    for MODE in remote_write remote_apply; do
        local t
        t=$(grep "VACUUM FULL wall time" "$RESULTS_DIR/s12_${MODE}.log" | awk '{print $(NF-1), $NF}')
        printf "  %-15s: %s\n" "$MODE" "$t"
    done
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 13: Hash index VACUUM — dual snapshot conflict + cleanup lock
# ══════════════════════════════════════════════════════════════════════════════
scenario13() {
    hdr "SCENARIO 13: Hash index VACUUM — dual snapshot conflict + buffer cleanup lock"
    echo "  Source: hash_xlog.c:991-1082, hash_xlog_vacuum_one_page()"
    echo "  XLOG_HASH_VACUUM_ONE_PAGE is the only WAL record type that calls"
    echo "  BOTH conflict resolution mechanisms in sequence:"
    echo "    Step 1: ResolveRecoveryConflictWithSnapshot(snapshotConflictHorizon)"
    echo "            — cancels/waits for standby sessions with old snapshots."
    echo "    Step 2: XLogReadBufferForRedoExtended(..., get_cleanup_lock=true)"
    echo "            — LockBufferForCleanup() waits for all buffer pins to drop."
    echo "  Scenarios 2/7 use only Step 1; scenario 9 uses only Step 2."
    echo "  S13 requires both an old snapshot AND concurrent bucket page pins."
    echo ""

    set_sync_mode "local"
    log "Loading hash_test (200K rows, hash index, 100K dead tuples — ~15s)..."
    $PSQL -f $SQL_DIR/scenario13_hash_vacuum/setup.sql >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"

        # Recreate dead tuples for each mode (they were vacuumed in last iteration
        # or this is the first run after setup).
        if [ "$MODE" = "remote_apply" ]; then
            set_sync_mode "remote_write"
            log "Re-inserting and re-deleting rows to recreate dead hash entries..."
            $PSQL -c "SET synchronous_commit TO local;
                      INSERT INTO hash_test SELECT i, md5(i::text)
                      FROM generate_series(200001, 400000) i;
                      DELETE FROM hash_test WHERE id % 2 = 0;" >/dev/null
            wait_for_catchup 120
            $PSQL -c "CHECKPOINT;" >/dev/null
            sleep 2
        fi

        set_sync_mode "$MODE"
        $PSQL -c "CHECKPOINT;" >/dev/null
        sleep 2

        # Start the standby blocker: REPEATABLE READ scan gives both
        # (a) a long-lived snapshot triggering the Step 1 conflict, and
        # (b) bucket page pins during scanning triggering Step 2.
        log "Starting standby blocker (REPEATABLE READ, 90s)..."
        $PSQL_S -f $SQL_DIR/scenario13_hash_vacuum/standby_blocker.sql &
        BLOCKER_PID=$!
        sleep 3

        local active
        active=$($PSQL_S -tAc \
            "SELECT count(*) FROM pg_stat_activity
             WHERE query LIKE '%pg_sleep%' AND state='active';" 2>/dev/null || echo 0)
        log "Active blocker sessions on standby: $active"

        # Run VACUUM on hash_test with local sync to generate XLOG_HASH_VACUUM_ONE_PAGE.
        # This creates the WAL records that will stall replay when the blocker holds
        # the snapshot + pins.
        set_sync_mode "$MODE"
        log "VACUUM hash_test (generates XLOG_HASH_VACUUM_ONE_PAGE WAL, local sync)..."
        $PSQL -c "SET synchronous_commit TO local" \
              -c "VACUUM hash_test;" 2>&1 | tail -1
        sleep 1
        show_repl

        # Run probe while the replay stall is in effect
        log "Starting probe pgbench (8 clients, 30s)..."
        $PGBENCH \
            -f $SQL_DIR/scenario13_hash_vacuum/workload.sql \
            -c 8 -j 4 -T 30 -P 5 --progress-timestamp 2>&1 \
            | tee "$RESULTS_DIR/s13_${MODE}.log"

        show_repl
        kill_standby_sessions
        wait $BLOCKER_PID 2>/dev/null || true
        sleep 5
        wait_for_catchup 120
        echo ""
    done

    print_comparison "SCENARIO 13" "$RESULTS_DIR/s13_remote_write.log" \
                     "$RESULTS_DIR/s13_remote_apply.log" 3.0
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 14: Replay throughput saturation — single-threaded replay ceiling
# ══════════════════════════════════════════════════════════════════════════════
scenario14() {
    hdr "SCENARIO 14: Replay throughput saturation — single-threaded replay ceiling"
    echo "  Mechanism: WAL replay is single-threaded (one startup process)."
    echo "  Each commit updates 50 rows SCATTERED across the table × 11 indexes"
    echo "  = ~550 distinct page modifications → ~300 KB WAL per commit."
    echo ""
    echo "  remote_write: primary waits only for WAL bytes to reach standby memory."
    echo "  remote_apply: every commit competes for the same single replay thread."
    echo ""
    echo "  At low concurrency replay keeps up. As concurrency rises, combined WAL"
    echo "  generation from all clients approaches single-threaded replay throughput"
    echo "  → commits queue behind the startup process → added latency climbs."
    echo ""

    set_sync_mode "local"
    log "Loading saturation_test (500K rows, 10 indexes — takes ~30s)..."
    $PSQL -f "$SQL_DIR/scenario14_replay_saturation/setup.sql" >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup 60

    local -a LEVELS=(1 2 4 8 16 32 64 128)

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"

        for CLIENTS in "${LEVELS[@]}"; do
            local THREADS
            THREADS=$(( CLIENTS < 8 ? CLIENTS : 8 ))
            log "pgbench concurrency=$CLIENTS clients (20s)..."
            $PGBENCH \
                -f "$SQL_DIR/scenario14_replay_saturation/workload.sql" \
                -c "$CLIENTS" -j "$THREADS" -T 20 \
                --no-vacuum 2>&1 \
                | tee "$RESULTS_DIR/s14_${MODE}_c${CLIENTS}.log"
            show_repl
            wait_for_catchup 30
        done

        # Canonical log for report.sh = highest-concurrency run
        cp "$RESULTS_DIR/s14_${MODE}_c128.log" "$RESULTS_DIR/s14_${MODE}.log"
    done

    hdr "SCENARIO 14 — RESULTS (avg latency ms vs concurrency)"
    echo ""
    printf "  %-8s  %14s  %14s  %10s\n" "clients" "remote_write" "remote_apply" "added_ms"
    printf "  %-8s  %14s  %14s  %10s\n" "-------" "------------" "------------" "--------"
    for CLIENTS in "${LEVELS[@]}"; do
        local rw_lat ra_lat added
        rw_lat=$(grep 'latency average' \
            "$RESULTS_DIR/s14_remote_write_c${CLIENTS}.log" 2>/dev/null \
            | head -1 | awk -F'= ' '{print $2}' | awk '{print $1}')
        ra_lat=$(grep 'latency average' \
            "$RESULTS_DIR/s14_remote_apply_c${CLIENTS}.log" 2>/dev/null \
            | head -1 | awk -F'= ' '{print $2}' | awk '{print $1}')
        if [ -n "$rw_lat" ] && [ -n "$ra_lat" ]; then
            added=$(awk "BEGIN {printf \"%+.1f\", $ra_lat - $rw_lat}")
            printf "  %-8s  %14s  %14s  %10s\n" "$CLIENTS" "$rw_lat" "$ra_lat" "$added"
        else
            printf "  %-8s  %14s  %14s  %10s\n" \
                "$CLIENTS" "${rw_lat:-N/A}" "${ra_lat:-N/A}" "N/A"
        fi
    done
    echo ""
    echo "  Growing added_ms with client count = replay saturation onset."
    echo "  Flat added_ms = replay keeps up; all overhead is network RTT."
    echo "  50 scattered rows × 11 indexes = ~550 page mods per commit."
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 15: Anti-wraparound VACUUM — large WAL volume, zero conflicts
# ══════════════════════════════════════════════════════════════════════════════
# NOT IN DEFAULTS: VACUUM FREEZE WAL rate (~40 MB/s) < replay throughput (~500 MB/s).
# but single-threaded replay handles 500+ MB/s on modern hardware.  The effect
# only manifests with very large tables (100 GB+) where the sheer WAL volume
# exceeds replay throughput.  Run manually:  bash run.sh 15
scenario15() {
    hdr "SCENARIO 15: Anti-wraparound VACUUM — large WAL volume, zero conflicts"
    echo "  Mechanism: VACUUM FREEZE writes XLOG_HEAP2_FREEZE_PAGE for every page."
    echo "  Anti-wraparound autovacuum bypasses cost delay and cannot be cancelled,"
    echo "  generating WAL proportional to table size at full I/O speed."
    echo ""
    echo "  A CHECKPOINT before VACUUM FREEZE causes full-page images (8 KB each)"
    echo "  for every page touched — amplifying WAL to match on-disk table size."
    echo ""
    echo "  Measurement: pgbench probe on a SEPARATE table runs during VACUUM FREEZE."
    echo "  Under remote_apply, probe commits must wait for VACUUM's FREEZE_PAGE WAL"
    echo "  to be replayed before the probe's commit position is reached."
    echo ""
    echo "  SCALE: 1 TB table → ~130M pages → ~1 TB of FPI WAL per VACUUM FREEZE."
    echo "  At 300 MB/s replay: ~55 minutes of remote_apply stall."
    echo ""

    set_sync_mode "local"
    log "Loading antiwrap_test (5M rows — takes ~120s)..."
    $PSQL -f "$SQL_DIR/scenario15_antiwrap_vacuum/setup.sql" >/dev/null 2>&1
    set_sync_mode "remote_write"
    wait_for_catchup 600

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"

        # Update ALL rows to ensure every page has unfrozen tuples.
        # Use deterministic transformation so both modes see identical work.
        set_sync_mode "local"
        log "Updating all rows to create unfrozen tuples (local sync, ~60s)..."
        $PSQL -c "UPDATE antiwrap_test SET payload = md5(id::text || '${MODE}');" >/dev/null

        # CHECKPOINT forces FPI on the next write to every page.
        log "CHECKPOINT (forces FPIs on next VACUUM FREEZE)..."
        $PSQL -c "CHECKPOINT;" >/dev/null
        wait_for_catchup 600
        sleep 2

        set_sync_mode "$MODE"

        # Start probe pgbench — measures commit latency during VACUUM FREEZE
        log "Starting probe pgbench (8 clients, 60s)..."
        $PGBENCH \
            -f "$SQL_DIR/scenario15_antiwrap_vacuum/workload_probe.sql" \
            -c 8 -j 4 -T 60 -P 5 --progress-timestamp 2>&1 \
            | tee "$RESULTS_DIR/s15_${MODE}.log" &
        PGBENCH_PID=$!

        sleep 5

        # Run VACUUM FREEZE in background with local sync.
        # It generates FREEZE_PAGE WAL for every page; replay must process all
        # of this before reaching the probe's commit records in the WAL stream.
        local lsn_before
        lsn_before=$($PSQL -tAc "SELECT pg_current_wal_lsn();" 2>/dev/null \
                     || echo "0/0")

        log "Running VACUUM FREEZE (local sync, generates heavy WAL)..."
        local t0_ms
        t0_ms=$(date +%s%3N)
        $PSQL -c "SET vacuum_freeze_min_age = 0" \
              -c "SET synchronous_commit TO local" \
              -c "VACUUM FREEZE antiwrap_test" >/dev/null
        local elapsed_ms=$(( $(date +%s%3N) - t0_ms ))

        local wal_generated
        wal_generated=$($PSQL -tAc \
            "SELECT pg_size_pretty(
                 pg_wal_lsn_diff(pg_current_wal_lsn(), '${lsn_before}'));" \
            2>/dev/null || echo "N/A")

        log "  VACUUM FREEZE done in ${elapsed_ms}ms, WAL generated: ${wal_generated}"

        log "Waiting for pgbench to finish..."
        wait $PGBENCH_PID || true

        show_repl
        wait_for_catchup 600
        echo ""
    done

    print_comparison "SCENARIO 15" "$RESULTS_DIR/s15_remote_write.log" \
                     "$RESULTS_DIR/s15_remote_apply.log" 1.2
}

# ── MAIN ─────────────────────────────────────────────────────────────────────
main() {
    local sync_state
    sync_state=$($PSQL -tAc "SELECT sync_state FROM pg_stat_replication LIMIT 1;" 2>/dev/null || echo "")
    if [ "$sync_state" != "sync" ] && [ "$sync_state" != "quorum" ]; then
        err "Replication is not synchronous (sync_state='${sync_state:-none}'). Aborting."
        err "Run setup_patroni_env.sh first."
        exit 1
    fi
    log "Replication OK (sync_state=$sync_state)"

    local scenarios=("${@}")
    if [ ${#scenarios[@]} -eq 0 ]; then
        scenarios=(1 2 3 4 7 8 10 11 12 14)
    fi

    for s in "${scenarios[@]}"; do
        case "$s" in
            1)  scenario1  ;;
            2)  scenario2  ;;
            3)  scenario3  ;;
            4)  scenario4  ;;
            5)  scenario5  ;;
            6)  scenario6  ;;
            7)  scenario7  ;;
            8)  scenario8  ;;
            9)  scenario9  ;;
            10) scenario10 ;;
            11) scenario11 ;;
            12) scenario12 ;;
            13) scenario13 ;;
            14) scenario14 ;;
            15) scenario15 ;;
            *)  warn "Unknown scenario: $s" ;;
        esac
    done

    hdr "OVERALL SUMMARY (scenarios ${scenarios[*]})"
    echo ""
    printf "  %-4s %14s %14s %14s %8s\n" "" "remote_write" "remote_apply" "added_latency" "ratio"
    printf "  %-4s %14s %14s %14s %8s\n" "" "(ms)" "(ms)" "(ms)" ""
    echo "  ─────────────────────────────────────────────────────────────────"
    for S_NUM in "${scenarios[@]}"; do
        local rw_f="$RESULTS_DIR/s${S_NUM}_remote_write.log"
        local ra_f="$RESULTS_DIR/s${S_NUM}_remote_apply.log"
        if [ -f "$rw_f" ] && [ -f "$ra_f" ]; then
            # Detect blocking: 0-TPS intervals in remote_apply progress
            local zero_int total_int
            read -r zero_int total_int <<< "$(parse_blocking_stats "$ra_f")"

            if [ "$zero_int" -gt 0 ] 2>/dev/null; then
                local blocked_s=$(( zero_int * 5 ))
                local total_s=$(( total_int * 5 ))
                local lat_rw tps_rw tps_ra tps_ratio
                lat_rw=$(extract_avg_latency "$rw_f")
                tps_rw=$(extract_tps "$rw_f")
                tps_ra=$(extract_tps "$ra_f")
                tps_ratio=$(awk "BEGIN {printf \"%.0f\", $tps_rw / $tps_ra}")
                printf "  S%-3d %14s    ${RED}${BOLD}BLOCKED${NC}  ← 0 TPS for %d/%ds (%sx TPS drop)\n" \
                    "$S_NUM" "${lat_rw:-?}" "$blocked_s" "$total_s" "$tps_ratio"
            else
                local lat_rw lat_ra added ratio
                # S4 uses time-weighted avg (burst scenario)
                if [ "$S_NUM" = "4" ]; then
                    lat_rw=$(extract_time_weighted_latency "$rw_f")
                    lat_ra=$(extract_time_weighted_latency "$ra_f")
                else
                    lat_rw=$(extract_avg_latency "$rw_f")
                    lat_ra=$(extract_avg_latency "$ra_f")
                fi
                if [ -n "$lat_rw" ] && [ -n "$lat_ra" ]; then
                    added=$(awk "BEGIN {printf \"%.1f\", $lat_ra - $lat_rw}")
                    ratio=$(awk "BEGIN {printf \"%.1f\", $lat_ra / $lat_rw}")
                    printf "  S%-3d %14s %14s %+13.1f %7sx\n" \
                        "$S_NUM" "$lat_rw" "$lat_ra" "$added" "$ratio"
                fi
            fi
        fi
    done
    echo ""
    echo -e "  ${BOLD}added_latency = remote_apply − remote_write = pure replay overhead${NC}"
    echo ""
    echo -e "${BOLD}Per-5s progress lines in $RESULTS_DIR/ show latency spikes.${NC}"
    echo ""
    log "Done."
}

trap 'echo ""; warn "Interrupted."; kill_standby_sessions 2>/dev/null; exit 130' INT

main "$@"
