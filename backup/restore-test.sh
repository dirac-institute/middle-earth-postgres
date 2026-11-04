#!/bin/bash
# Test that the latest backup actually restores.
#
# Runs inside the backup container -- automatically after a full backup (see
# scheduler.sh) or by hand:
#
#   podman exec pg-backup restore-test.sh
#
# 1. Restores the latest backup into a scratch directory (/restore-scratch,
#    which is /service/shire/restore-scratch on the host) with archive_mode
#    off, so the test can never push anything back into the repository.
# 2. Starts a throwaway PostgreSQL on it with no TCP listener, replays WAL to
#    the end of the archive, and waits for it to promote.
# 3. Connects to every database and runs pg_amcheck (heap + btree checks).
# 4. Stops the server, deletes the scratch copy, and writes a dated
#    PASS/FAIL log to /backups/restore-test/.
#
# Never touches the live data directory or the live server.
set -uo pipefail

: "${RESTORE_TEST_AMCHECK:=yes}"
: "${RESTORE_TEST_KEEP_LOGS:=20}"

STANZA=main
SCRATCH=/restore-scratch
PGD=$SCRATCH/pgdata
# The test gets its own pgBackRest spool. restore clears the spool's archive
# queue, and the configured spool belongs to the live server's WAL archiver.
SPOOL=$SCRATCH/spool
SOCK=/tmp/restore-test-socket
RESULTS=/backups/restore-test
STAMP=$(date +%Y%m%d-%H%M%S)
LOG=$RESULTS/$STAMP.log

mkdir -p "$RESULTS"
exec > >(tee "$LOG") 2>&1

log()  { echo "$(date '+%F %T %Z') restore-test: $*"; }
pgsql() { psql -X -q -At -h "$SOCK" -U postgres "$@"; }

cleanup() {
    if [ -f "$PGD/postmaster.pid" ]; then
        pg_ctl -D "$PGD" stop -m fast -t 600 >/dev/null 2>&1 || true
    fi
    rm -rf -- "$PGD" "$SPOOL" "$SOCK" "$SCRATCH/postgres.log"
}

finish() {  # finish PASS|FAIL
    log "result: $1"
    cleanup
    exec >&- 2>&-; wait   # flush tee
    mv "$LOG" "$RESULTS/$STAMP-$1.log"
    # Keep only the most recent logs.
    ls -1t "$RESULTS"/*.log 2>/dev/null | tail -n +$(( RESTORE_TEST_KEEP_LOGS + 1 )) | xargs -r rm -f --
    [ "$1" = PASS ]
    exit
}
fail() { log "FAIL: $*"; finish FAIL; }

trap 'fail "interrupted"' TERM INT

[ -d "$SCRATCH" ] || fail "$SCRATCH is not mounted"
if [ -f "$PGD/postmaster.pid" ] && pg_ctl -D "$PGD" status >/dev/null 2>&1; then
    fail "another restore test appears to be running in $PGD"
fi
rm -rf -- "$PGD" "$SPOOL" "$SOCK"
mkdir -m 0700 "$PGD" "$SPOOL" "$SOCK" || fail "cannot create $PGD"

log "restoring latest backup into $PGD"
pgbackrest --stanza=$STANZA --pg1-path="$PGD" --spool-path="$SPOOL" restore \
    --archive-mode=off \
    --recovery-option="restore_command=pgbackrest --stanza=$STANZA --pg1-path=$PGD --spool-path=$SPOOL archive-get %f \"%p\"" \
    || fail "pgbackrest restore failed"
grep '^restore_command' "$PGD/postgresql.auto.conf" | sed 's/^/    /'

log "starting throwaway server and replaying WAL to the end of the archive"
pg_ctl -D "$PGD" -l "$SCRATCH/postgres.log" -w -t 86400 start -o "\
    -c config_file=/etc/postgresql/postgresql.conf \
    -c data_directory=$PGD \
    -c listen_addresses='' \
    -c unix_socket_directories=$SOCK \
    -c archive_mode=off \
    -c shared_buffers=1GB \
    -c effective_cache_size=4GB" \
    || { tail -50 "$SCRATCH/postgres.log"; fail "server did not start"; }

while [ "$(pgsql -d postgres -c 'SELECT pg_is_in_recovery()' 2>/dev/null)" != f ]; do
    pg_ctl -D "$PGD" status >/dev/null 2>&1 \
        || { tail -50 "$SCRATCH/postgres.log"; fail "server exited during recovery"; }
    sleep 10
done
grep -E 'recovery stopped|last completed transaction|archive recovery complete|selected new timeline' \
    "$SCRATCH/postgres.log" | sed 's/^/    /'
rm -f "$SCRATCH/postgres.log"

log "recovered; checking databases"
dbs=$(pgsql -d postgres -c "SELECT datname FROM pg_database WHERE datallowconn ORDER BY 1") \
    || fail "cannot list databases"
for db in $dbs; do
    info=$(pgsql -d "$db" -c "SELECT pg_size_pretty(pg_database_size(current_database())) || ', ' || count(*) || ' relations' FROM pg_class") \
        || fail "cannot query database $db"
    log "  $db: $info"
done
log "  roles: $(pgsql -d postgres -c "SELECT string_agg(rolname, ' ' ORDER BY rolname) FROM pg_roles WHERE rolname !~ '^pg_'")"

if [ "$RESTORE_TEST_AMCHECK" = yes ]; then
    log "running pg_amcheck on all databases"
    pg_amcheck -h "$SOCK" -U postgres --all --install-missing --jobs=4 \
        || fail "pg_amcheck reported corruption"
fi

finish PASS
