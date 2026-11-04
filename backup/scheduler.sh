#!/bin/bash
# Entrypoint for the backup container: a small scheduler around pgBackRest.
#
# On start:
#   - wait for the db, create the pgBackRest stanza (idempotent), run `check`
#   - if the repository has no backups yet, take a full backup immediately
# Then once a day at $BACKUP_TIME (container-local time, $TZ):
#   - on $FULL_BACKUP_DAY: full backup, then `pgbackrest verify`, then (if due)
#     a test restore -- see restore-test.sh
#   - other days: incremental backup
# Retention/expiry happens automatically at the end of every backup
# (repo1-retention-full in pgbackrest.conf).
#
# Status of the most recent runs is written to /backups/status/ so it can be
# checked from the host without reading logs.
set -uo pipefail

: "${BACKUP_TIME:=01:00}"        # HH:MM, local time
: "${FULL_BACKUP_DAY:=7}"        # ISO weekday: 1=Monday ... 7=Sunday
: "${RESTORE_TEST:=monthly}"     # monthly | weekly | off

STANZA=main
STATUS_DIR=/backups/status
export PGHOST=/var/run/postgresql PGUSER=postgres

log() { echo "$(date '+%F %T %Z') scheduler: $*"; }

# Exit promptly on `podman stop` (bash as PID 1 ignores SIGTERM otherwise).
trap 'log "stopping"; exit 0' TERM INT
nap() { sleep "$1" & wait $!; }

status() {  # status <name> <OK|FAIL> <detail>
    mkdir -p "$STATUS_DIR"
    printf '%s %s %s\n' "$(date '+%F %T %Z')" "$2" "$3" > "$STATUS_DIR/$1.tmp" &&
        mv "$STATUS_DIR/$1.tmp" "$STATUS_DIR/$1"
}

run_backup() {  # run_backup full|incr
    log "starting $1 backup"
    if pgbackrest --stanza=$STANZA backup --type="$1"; then
        status last-backup OK "$1"
        log "$1 backup complete"
        return 0
    fi
    status last-backup FAIL "$1"
    log "ERROR: $1 backup failed"
    return 1
}

run_verify() {
    log "verifying repository"
    if pgbackrest --stanza=$STANZA verify; then
        status last-verify OK verify
    else
        status last-verify FAIL verify
        log "ERROR: repository verification failed"
    fi
}

restore_test_due() {
    case "$RESTORE_TEST" in
        weekly)  return 0 ;;
        monthly) [ "$(date +%-d)" -le 7 ] ;;   # first full-backup day of the month
        *)       return 1 ;;
    esac
}

seconds_until_next_run() {
    local now target
    now=$(date +%s)
    target=$(date -d "today $BACKUP_TIME" +%s)
    [ "$target" -gt "$now" ] || target=$(date -d "tomorrow $BACKUP_TIME" +%s)
    echo $(( target - now ))
}

# ── Startup ─────────────────────────────────────────────────────────────────
log "waiting for the database"
until pg_isready -q; do nap 5; done

until pgbackrest --stanza=$STANZA stanza-create; do
    log "ERROR: stanza-create failed; retrying in 5 minutes"
    nap 300
done
pgbackrest --stanza=$STANZA check || log "WARNING: pgbackrest check failed (is WAL archiving working?)"

if [ "$(pgbackrest --stanza=$STANZA info --output=json | jq '.[0].backup | length')" = 0 ]; then
    log "repository has no backups yet"
    run_backup full
fi

log "schedule: daily at $BACKUP_TIME $(date +%Z), full on ISO weekday $FULL_BACKUP_DAY, restore test $RESTORE_TEST"

# ── Daily loop ──────────────────────────────────────────────────────────────
while true; do
    secs=$(seconds_until_next_run)
    log "next backup in $(( secs / 3600 ))h$(( secs % 3600 / 60 ))m"
    nap "$secs"

    if [ "$(date +%u)" = "$FULL_BACKUP_DAY" ]; then
        run_backup full && {
            run_verify
            restore_test_due && /usr/local/bin/restore-test.sh
        }
    else
        run_backup incr
    fi
    nap 60   # don't fire twice within the same minute
done
