#!/usr/bin/env bash
# setup_patroni_env.sh — one-time environment preparation for Patroni clusters
#
# Run ONCE before any benchmark run:
#   source syncrep.conf && bash setup_patroni_env.sh
#
# What this does:
#   1. Verifies connectivity to primary and standby
#   2. Confirms roles (primary is not in recovery, standby is)
#   3. Confirms synchronous replication is active
#   4. Creates the bench database on the primary
#   5. Configures the standby for test conditions:
#        max_standby_streaming_delay = -1   wait forever, never cancel queries
#        hot_standby_feedback        = off  let primary VACUUM run freely
#
# Note: synchronous_standby_names is expected to be set by Patroni
# (synchronous_mode: true) or manually before running this script.
# This script does NOT set it, because Patroni may overwrite it.

set -euo pipefail

# Auto-source syncrep.conf from the script's own directory when the required
# env vars are not already in the environment.  This lets you run the script
# directly (bash setup_patroni_env.sh) without sourcing the conf first.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${PRIMARY_HOST:-}" && -f "$SCRIPT_DIR/syncrep.conf" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/syncrep.conf"
fi

: "${PRIMARY_HOST:?syncrep.conf not found or PRIMARY_HOST not set}"
: "${STANDBY_HOST:?syncrep.conf not found or STANDBY_HOST not set}"
: "${PGUSER:?syncrep.conf not found or PGUSER not set}"
: "${PGDATABASE:?syncrep.conf not found or PGDATABASE not set}"

export PGPASSWORD="${PGPASSWORD:-}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
STANDBY_PORT="${STANDBY_PORT:-5432}"

PSQL_P="psql -h $PRIMARY_HOST -p $PRIMARY_PORT -U $PGUSER"
PSQL_S="psql -h $STANDBY_HOST -p $STANDBY_PORT -U $PGUSER"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓${NC}  $*"; }
fail() { echo -e "${RED}  ✗${NC}  $*"; exit 1; }
warn() { echo -e "${YELLOW}  !${NC}  $*"; }
hdr()  { echo -e "\n${BOLD}${CYAN}--- $* ---${NC}"; }

echo -e "\n${BOLD}syncrep environment setup${NC}"

# ── 1. Connectivity ──────────────────────────────────────────────────────────
hdr "Connectivity"

$PSQL_P postgres -c "SELECT 1" -tA >/dev/null 2>&1 \
    && ok "Primary reachable  ($PRIMARY_HOST:$PRIMARY_PORT)" \
    || fail "Cannot connect to primary at $PRIMARY_HOST:$PRIMARY_PORT — check host/port/auth"

$PSQL_S postgres -c "SELECT 1" -tA >/dev/null 2>&1 \
    && ok "Standby reachable  ($STANDBY_HOST:$STANDBY_PORT)" \
    || fail "Cannot connect to standby at $STANDBY_HOST:$STANDBY_PORT — check host/port/auth"

# ── 2. Role confirmation ─────────────────────────────────────────────────────
hdr "Role verification"

is_primary=$($PSQL_P postgres -tAc "SELECT NOT pg_is_in_recovery()" 2>/dev/null || echo "f")
is_standby=$($PSQL_S postgres -tAc "SELECT pg_is_in_recovery()"     2>/dev/null || echo "f")

[ "$is_primary" = "t" ] \
    || fail "$PRIMARY_HOST is in recovery — point PRIMARY_HOST at the actual primary"
[ "$is_standby" = "t" ] \
    || fail "$STANDBY_HOST is NOT in recovery — point STANDBY_HOST at an actual standby"

ok "Primary ($PRIMARY_HOST) is not in recovery"
ok "Standby ($STANDBY_HOST) is in recovery"

# ── 3. Synchronous replication ───────────────────────────────────────────────
hdr "Synchronous replication"

sync_state=$($PSQL_P postgres -tAc \
    "SELECT sync_state FROM pg_stat_replication WHERE sync_state IN ('sync','quorum') LIMIT 1;" \
    2>/dev/null || echo "")

if [ "$sync_state" = "sync" ] || [ "$sync_state" = "quorum" ]; then
    ok "Synchronous replication active (sync_state=$sync_state)"
else
    warn "No synchronous standby detected (sync_state='${sync_state:-none}')"
    echo ""
    echo "  Patroni synchronous mode:"
    echo "    Add to patroni.yml → postgresql.parameters:"
    echo "      synchronous_standby_names: '*'"
    echo "    Or enable synchronous_mode: true in patroni.yml bootstrap.dcs"
    echo ""
    echo "  Manual (non-Patroni-managed):"
    echo "    psql -h $PRIMARY_HOST -U $PGUSER postgres \\"
    echo "      -c \"ALTER SYSTEM SET synchronous_standby_names = '*';\" \\"
    echo "      -c \"SELECT pg_reload_conf();\""
    echo ""
    echo "  Re-run this script after enabling sync replication."
    exit 1
fi

echo ""
$PSQL_P postgres -c "
    SELECT pid, application_name, sync_state,
           write_lag, flush_lag, replay_lag,
           pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
    FROM pg_stat_replication;" 2>/dev/null || true

# ── 4. Create bench database ─────────────────────────────────────────────────
hdr "Database"

db_exists=$($PSQL_P postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '$PGDATABASE'" 2>/dev/null || echo "")
if [ "$db_exists" = "1" ]; then
    ok "Database '$PGDATABASE' already exists"
else
    $PSQL_P postgres -c "CREATE DATABASE $PGDATABASE;" >/dev/null
    ok "Created database '$PGDATABASE'"
fi

# ── 5. Standby configuration ─────────────────────────────────────────────────
hdr "Standby configuration"

# max_standby_streaming_delay = -1
#   Without this, PostgreSQL cancels standby queries after the delay and replay
#   unblocks automatically.  Setting -1 means "wait forever" — which is what
#   the conflict scenarios (S2, S7, S8, S9) rely on to hold replay blocked.
#
# hot_standby_feedback = off
#   When on, the standby tells the primary which XIDs are still in use, so the
#   primary's VACUUM will not remove rows that an open standby snapshot still
#   needs.  That defeats scenarios 2 and 7 (no conflict WAL is generated).

$PSQL_S postgres -c "ALTER SYSTEM SET max_standby_streaming_delay = '-1';" >/dev/null
$PSQL_S postgres -c "ALTER SYSTEM SET hot_standby_feedback = off;"         >/dev/null
$PSQL_S postgres -c "SELECT pg_reload_conf();"                              >/dev/null

delay=$(   $PSQL_S postgres -tAc "SHOW max_standby_streaming_delay;")
feedback=$(  $PSQL_S postgres -tAc "SHOW hot_standby_feedback;")

ok "max_standby_streaming_delay = $delay"
ok "hot_standby_feedback        = $feedback"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Setup complete.${NC}  To run benchmarks:"
echo ""
echo "  bash run.sh                # all 15 scenarios"
echo "  bash run.sh 2 7 8         # specific scenarios"
echo ""
