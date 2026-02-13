#!/bin/bash
set -e

export PGDATA="${PGDATA:-/var/lib/postgresql/data}"

# If running as root, fix ownership and re-exec as postgres
if [ "$(id -u)" = '0' ]; then
    mkdir -p "$PGDATA"
    chown -R postgres:postgres "$PGDATA"
    chmod 0700 "$PGDATA"
    exec gosu postgres bash /standby-entrypoint.sh "$@"
fi

# First start: take a base backup from the primary
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "[standby] Waiting for primary to accept connections..."
    until pg_isready -h primary -U postgres -q 2>/dev/null; do
        sleep 1
    done

    echo "[standby] Running pg_basebackup..."
    pg_basebackup \
        -h primary \
        -U postgres \
        -D "$PGDATA" \
        -Fp -Xs -P -R

    echo "[standby] Base backup complete."
fi

echo "[standby] Starting PostgreSQL in recovery mode..."
exec postgres \
    -c shared_buffers=48MB \
    -c effective_cache_size=64MB \
    -c hot_standby=on \
    -c max_standby_streaming_delay=-1 \
    -c hot_standby_feedback=off \
    -c recovery_prefetch=off \
    -c maintenance_work_mem=32MB \
    -c log_min_messages=warning
