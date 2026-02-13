#!/bin/bash
set -e

# Ensure replication connections are allowed
echo "host replication all all trust" >> "$PGDATA/pg_hba.conf"

# Enable synchronous replication via postgresql.auto.conf.
# We CANNOT put these in the docker-compose command because the Docker
# entrypoint starts a temporary server for initialisation (CREATE DATABASE,
# running initdb scripts, etc.). With synchronous_standby_names='*' and
# no standby connected, every WAL-writing transaction (including
# CREATE DATABASE) deadlocks waiting for a sync standby that doesn't exist.
#
# ALTER SYSTEM writes to postgresql.auto.conf, which is read when the
# real server starts — at which point the standby will connect.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    ALTER SYSTEM SET synchronous_standby_names = '*';
    ALTER SYSTEM SET synchronous_commit = 'remote_write';
EOSQL
