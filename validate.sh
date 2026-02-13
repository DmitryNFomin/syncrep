#!/usr/bin/env bash
# validate.sh — Bring up a 2-node sync-rep cluster in Docker and run all
#                three scenarios to show the remote_write vs remote_apply delta.
#
# Usage:  bash validate.sh
# Prereq: docker compose v2
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"

# Use sudo if the current user can't talk to the Docker socket directly
DOCKER=docker
if ! $DOCKER info >/dev/null 2>&1; then
    DOCKER="sudo docker"
fi
COMPOSE="$DOCKER compose -f $SCRIPT_DIR/docker/docker-compose.yml"

# Container helpers
P="$DOCKER exec syncrep-primary"
S="$DOCKER exec syncrep-standby"
PSQL_P="$P psql -U postgres -d bench -v ON_ERROR_STOP=1"
PSQL_S="$S psql -U postgres -d bench -v ON_ERROR_STOP=1"
PGBENCH="$P pgbench -U postgres --no-vacuum bench"

# Durations (seconds)
BENCH_DUR=45
BLOCKER_SLEEP=70

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
    log "Waiting for primary..."
    for _ in $(seq 1 60); do
        $P pg_isready -U postgres -q 2>/dev/null && return 0
        sleep 1
    done
    err "Primary did not become ready"; exit 1
}

wait_for_standby() {
    log "Waiting for standby..."
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
    for _ in $(seq 1 120); do
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
    warn "Replay did not fully catch up (lag=$lag bytes)"
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
    # Extract first "latency average = X.XXX ms" (overall, not per-script)
    grep 'latency average' "$1" | head -1 | awk -F'= ' '{print $2}' | awk '{print $1}'
}

extract_tps() {
    grep '^tps' "$1" | head -1 | awk -F'= ' '{print $2}' | awk '{print $1}'
}

# Kill any active blocker queries on the standby
kill_standby_blockers() {
    $PSQL_S -tAc "
      SELECT pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE query LIKE '%pg_sleep%'
        AND pid != pg_backend_pid();" >/dev/null 2>&1 || true
}

# ── SCENARIO 1 ───────────────────────────────────────────────────────────────
scenario1() {
    hdr "SCENARIO 1: Index-heavy UPDATE saturation"
    echo "  Strategy: 10 secondary indexes, 32 pgbench clients"
    echo "  Primary parallelises UPDATEs; replay is single-threaded."
    echo ""

    log "Loading data (2M rows, 10 indexes — takes ~1-2 min)..."
    $PSQL_P -f /bench/scenario1_saturate_indexes/setup.sql >/dev/null
    wait_for_catchup

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"

        # Checkpoint so first page touches generate FPIs → more WAL per record
        $PSQL_P -c "CHECKPOINT;" >/dev/null
        sleep 2

        log "Running pgbench (32 clients, ${BENCH_DUR}s)..."
        $PGBENCH \
            -f /bench/scenario1_saturate_indexes/workload.sql \
            -c 32 -j 8 -T "$BENCH_DUR" -P 5 --progress-timestamp \
            2>&1 | tee "$RESULTS_DIR/s1_${MODE}.log"

        show_repl
        echo ""
    done

    wait_for_catchup

    # ── Compare ──
    local lat_rw lat_ra tps_rw tps_ra
    lat_rw=$(extract_avg_latency "$RESULTS_DIR/s1_remote_write.log")
    lat_ra=$(extract_avg_latency "$RESULTS_DIR/s1_remote_apply.log")
    tps_rw=$(extract_tps "$RESULTS_DIR/s1_remote_write.log")
    tps_ra=$(extract_tps "$RESULTS_DIR/s1_remote_apply.log")

    hdr "SCENARIO 1 — RESULTS"
    printf "  %-20s %12s %12s\n"   ""            "remote_write" "remote_apply"
    printf "  %-20s %12s %12s\n"   "avg latency (ms)" "$lat_rw" "$lat_ra"
    printf "  %-20s %12s %12s\n"   "TPS"              "$tps_rw" "$tps_ra"

    if [ -n "$lat_rw" ] && [ -n "$lat_ra" ]; then
        local ratio
        ratio=$(awk "BEGIN {printf \"%.1f\", $lat_ra / $lat_rw}")
        echo ""
        echo -e "  Latency ratio (apply/write): ${BOLD}${ratio}x${NC}"
        if awk "BEGIN {exit !($lat_ra > $lat_rw * 1.3)}"; then
            echo -e "  ${GREEN}PASS${NC} — remote_apply latency is measurably higher"
        else
            echo -e "  ${YELLOW}MARGINAL${NC} — delta is small (try more clients or slower disk)"
        fi
    fi
    echo ""
}

# ── SCENARIO 2 ───────────────────────────────────────────────────────────────
scenario2() {
    hdr "SCENARIO 2: Apply blocked by standby query conflict"
    echo "  Strategy: REPEATABLE READ on standby holds snapshot;"
    echo "  VACUUM WAL conflicts with it; replay stops entirely."
    echo ""

    log "Loading data (500K rows)..."
    $PSQL_P -f /bench/scenario2_blocked_conflict/setup.sql >/dev/null
    wait_for_catchup

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"

        # 1. Start blocker on standby (holds snapshot for ${BLOCKER_SLEEP}s)
        log "Starting REPEATABLE READ blocker on standby (${BLOCKER_SLEEP}s)..."
        $PSQL_S <<SQL &
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM orders WHERE status = 'delivered';
SELECT pg_sleep(${BLOCKER_SLEEP});
COMMIT;
SQL
        BLOCKER_PID=$!
        sleep 3

        # Verify blocker is active
        local active
        active=$($PSQL_S -tAc \
            "SELECT count(*) FROM pg_stat_activity
             WHERE query LIKE '%pg_sleep%' AND state='active';" 2>/dev/null || echo 0)
        log "Blocker sessions on standby: $active"

        # 2. Create dead tuples + vacuum (using local commit to avoid deadlock
        #    when testing remote_apply — replay is about to be blocked)
        log "Creating dead tuples + VACUUM (sync_commit=local to avoid deadlock)..."
        $PSQL_P \
            -c "SET synchronous_commit TO local" \
            -c "DELETE FROM orders WHERE id IN (
                    SELECT id FROM orders
                    WHERE status IN ('delivered','cancelled')
                    ORDER BY id LIMIT 50000)" \
            >/dev/null

        $PSQL_P \
            -c "SET synchronous_commit TO local" \
            -c "VACUUM orders" \
            >/dev/null 2>&1

        sleep 2
        log "Replay state after VACUUM (should show lag if conflict hit):"
        show_repl

        # 3. Run pgbench — under remote_write this should be fast,
        #    under remote_apply it should stall because replay is blocked
        log "Running pgbench (8 clients, ${BENCH_DUR}s) with $MODE..."
        $PGBENCH \
            -f /bench/scenario2_blocked_conflict/workload_steady.sql \
            -c 8 -j 4 -T "$BENCH_DUR" -P 5 --progress-timestamp \
            2>&1 | tee "$RESULTS_DIR/s2_${MODE}.log"

        show_repl

        # 4. Cleanup: kill blocker, wait for catchup
        kill_standby_blockers
        wait $BLOCKER_PID 2>/dev/null || true
        wait_for_catchup
        echo ""
    done

    # ── Compare ──
    local lat_rw lat_ra tps_rw tps_ra
    lat_rw=$(extract_avg_latency "$RESULTS_DIR/s2_remote_write.log")
    lat_ra=$(extract_avg_latency "$RESULTS_DIR/s2_remote_apply.log")
    tps_rw=$(extract_tps "$RESULTS_DIR/s2_remote_write.log")
    tps_ra=$(extract_tps "$RESULTS_DIR/s2_remote_apply.log")

    hdr "SCENARIO 2 — RESULTS"
    printf "  %-20s %12s %12s\n"   ""            "remote_write" "remote_apply"
    printf "  %-20s %12s %12s\n"   "avg latency (ms)" "$lat_rw" "$lat_ra"
    printf "  %-20s %12s %12s\n"   "TPS"              "$tps_rw" "$tps_ra"

    if [ -n "$lat_rw" ] && [ -n "$lat_ra" ]; then
        local ratio
        ratio=$(awk "BEGIN {printf \"%.1f\", $lat_ra / $lat_rw}")
        echo ""
        echo -e "  Latency ratio (apply/write): ${BOLD}${ratio}x${NC}"
        if awk "BEGIN {exit !($lat_ra > $lat_rw * 5)}"; then
            echo -e "  ${GREEN}PASS${NC} — remote_apply dramatically stalled by blocked replay"
        elif awk "BEGIN {exit !($lat_ra > $lat_rw * 1.5)}"; then
            echo -e "  ${YELLOW}PARTIAL${NC} — some effect visible but less dramatic than expected"
        else
            echo -e "  ${RED}FAIL${NC} — no significant difference (check standby config)"
        fi
    fi
    echo ""
}

# ── SCENARIO 3 ───────────────────────────────────────────────────────────────
scenario3() {
    hdr "SCENARIO 3: GIN + TOAST bursty apply pressure"
    echo "  Strategy: 3 GIN indexes + TOASTed bodies/metadata;"
    echo "  GIN pending list flushes cause replay bursts."
    echo ""

    log "Loading data (300K rows with TOAST — takes ~2-3 min)..."
    $PSQL_P -f /bench/scenario3_gin_toast/setup.sql >/dev/null
    wait_for_catchup

    for MODE in remote_write remote_apply; do
        log "── $MODE ──"
        set_sync_mode "$MODE"
        $PSQL_P -c "CHECKPOINT;" >/dev/null
        sleep 2

        log "Running pgbench (12 clients, ${BENCH_DUR}s, 70%% INSERT / 30%% UPDATE)..."
        # Must use bash -c inside container because the @N weight syntax
        # gets mangled by the docker exec argument splitting.
        $P bash -c "pgbench -U postgres --no-vacuum bench \
            -f '/bench/scenario3_gin_toast/workload_insert.sql@7' \
            -f '/bench/scenario3_gin_toast/workload_update.sql@3' \
            -c 12 -j 6 -T $BENCH_DUR -P 5 --progress-timestamp 2>&1" \
            | tee "$RESULTS_DIR/s3_${MODE}.log"

        # Flush GIN pending lists — may cause a visible spike in replay lag
        log "VACUUM to flush GIN pending lists..."
        $PSQL_P -c "SET synchronous_commit TO local; VACUUM tickets;" >/dev/null 2>&1
        show_repl
        echo ""
    done

    wait_for_catchup

    # ── Compare ──
    local lat_rw lat_ra tps_rw tps_ra
    lat_rw=$(extract_avg_latency "$RESULTS_DIR/s3_remote_write.log")
    lat_ra=$(extract_avg_latency "$RESULTS_DIR/s3_remote_apply.log")
    tps_rw=$(extract_tps "$RESULTS_DIR/s3_remote_write.log")
    tps_ra=$(extract_tps "$RESULTS_DIR/s3_remote_apply.log")

    hdr "SCENARIO 3 — RESULTS"
    printf "  %-20s %12s %12s\n"   ""            "remote_write" "remote_apply"
    printf "  %-20s %12s %12s\n"   "avg latency (ms)" "$lat_rw" "$lat_ra"
    printf "  %-20s %12s %12s\n"   "TPS"              "$tps_rw" "$tps_ra"

    if [ -n "$lat_rw" ] && [ -n "$lat_ra" ]; then
        local ratio
        ratio=$(awk "BEGIN {printf \"%.1f\", $lat_ra / $lat_rw}")
        echo ""
        echo -e "  Latency ratio (apply/write): ${BOLD}${ratio}x${NC}"
        if awk "BEGIN {exit !($lat_ra > $lat_rw * 1.3)}"; then
            echo -e "  ${GREEN}PASS${NC} — remote_apply shows GIN/TOAST replay overhead"
        else
            echo -e "  ${YELLOW}MARGINAL${NC} — effect is subtle (check per-5s progress lines for spikes)"
        fi
    fi
    echo ""
}

# ── MAIN ─────────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$RESULTS_DIR"

    hdr "Setting up Docker environment"

    # Clean start
    log "Tearing down any previous run..."
    $COMPOSE down -v 2>/dev/null || true

    log "Starting primary + standby..."
    $COMPOSE up -d

    wait_for_primary
    wait_for_standby
    wait_for_sync_rep
    show_repl

    # Run scenarios
    scenario1
    scenario2
    scenario3

    # ── Final summary ──
    hdr "OVERALL SUMMARY"
    echo ""
    for S_NUM in 1 2 3; do
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

    echo -e "${BOLD}See per-5s progress lines in results/ for detailed latency patterns.${NC}"
    echo ""
    log "Containers still running. To tear down: $COMPOSE down -v"
}

# Cleanup on Ctrl-C: kill background jobs, but leave containers for inspection
trap 'echo ""; warn "Interrupted. Containers left running for inspection."; \
      kill_standby_blockers 2>/dev/null; exit 130' INT

main "$@"
