#!/bin/bash
# Make the five standard roles match /run/secrets/postgres/<role>.
#
# Runs in the background on every db container start (see start.sh). The
# password files are authoritative: to change a password, edit the file and
# recreate the container. This script only ever CREATEs missing roles and
# ALTERs the five roles below. It never drops anything and never touches
# databases or any other role.
#
#   postgres     superuser
#   owner        LOGIN CREATEDB -- creates and owns application databases
#   readwrite    LOGIN, member of pg_read_all_data + pg_write_all_data
#   readonly     LOGIN, member of pg_read_all_data
#   replication  LOGIN REPLICATION -- for streaming read replicas
#
# The pg_*_all_data predefined roles apply to every table in every database,
# including ones created later, so no per-database grants are needed.
#
# It also creates the pg_stat_statements extension in the postgres database
# if it is missing (for the monitoring endpoint).
set -uo pipefail

SECRETS=/run/secrets/postgres
export PGHOST=/var/run/postgresql PGUSER=postgres PGDATABASE=postgres

log() { echo "sync-roles: $*" >&2; }

# Strip a trailing newline (and CR) so `echo secret > file` works as expected.
pw() { tr -d '\r\n' < "$SECRETS/$1"; }

sync_once() {
    psql -X -q -v ON_ERROR_STOP=1 \
        -v pw_postgres="$(pw postgres)" \
        -v pw_owner="$(pw owner)" \
        -v pw_readwrite="$(pw readwrite)" \
        -v pw_readonly="$(pw readonly)" \
        -v pw_replication="$(pw replication)" <<'SQL'
-- Keep the passwords out of the server log no matter how logging is set.
SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET log_min_error_statement = 'panic';

SELECT format('CREATE ROLE %I', r)
  FROM unnest(ARRAY['owner', 'readwrite', 'readonly', 'replication']) AS r
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r)
\gexec

ALTER ROLE postgres      WITH SUPERUSER LOGIN PASSWORD :'pw_postgres';
ALTER ROLE "owner"       WITH LOGIN CREATEDB NOSUPERUSER NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'pw_owner';
ALTER ROLE readwrite     WITH LOGIN NOCREATEDB NOSUPERUSER NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'pw_readwrite';
ALTER ROLE readonly      WITH LOGIN NOCREATEDB NOSUPERUSER NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'pw_readonly';
ALTER ROLE "replication" WITH LOGIN REPLICATION NOCREATEDB NOSUPERUSER NOCREATEROLE NOBYPASSRLS PASSWORD :'pw_replication';

GRANT pg_read_all_data, pg_write_all_data TO readwrite;
GRANT pg_read_all_data TO readonly;

-- Not a role, but the same kind of idempotent setup: the monitoring
-- endpoint reads query statistics from this view (see postgresql.conf).
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
}

# On a brand-new cluster the stock entrypoint starts and stops a temporary
# socket-only server before the real one, so keep retrying until a sync
# succeeds against a server that is up.
for attempt in $(seq 1 120); do
    if pg_isready -q && sync_once; then
        log "roles postgres, owner, readwrite, readonly, replication are in sync with $SECRETS"
        exit 0
    fi
    sleep 5
done
log "ERROR: could not sync roles after 10 minutes; passwords may be stale"
exit 1
