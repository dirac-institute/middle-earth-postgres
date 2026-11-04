#!/bin/bash
# Disaster recovery: rebuild /data/postgres from the pgBackRest repository in
# /service/shire/backups. Run as root on the host, after init.sh, with the
# db container NOT running and the data directory empty.
#
#   sudo ./restore.sh --list                         # show available backups
#   sudo ./restore.sh                                # latest backup + all WAL
#   sudo ./restore.sh --target-time "2026-11-04 09:30:00-08"
#   sudo ./restore.sh --set 20261101-010002F         # a specific backup
#   podman compose up -d                             # then start normally
#
# The restored cluster finishes WAL replay and promotes when the db container
# starts. This script refuses to run if there is anything in the data
# directory -- it will never overwrite an existing cluster.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
IMAGE=middle-earth-postgres/postgres:18
DATA_ROOT=/data/postgres
PGDATA_HOST=$DATA_ROOT/18/docker
BACKUPS=/service/shire/backups

die() { echo "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f "$ENV_FILE" ] || die "$ENV_FILE not found; run init.sh first"
# shellcheck source=/dev/null
source "$ENV_FILE"

mode=restore
opts=()
while [ $# -gt 0 ]; do
    case "$1" in
        --list)        mode=list ;;
        --target-time) [ $# -ge 2 ] || die "--target-time needs a value"
                       opts+=(--type=time "--target=$2" --target-action=promote); shift ;;
        --set)         [ $# -ge 2 ] || die "--set needs a value"
                       opts+=("--set=$2"); shift ;;
        -h|--help)     sed -n '2,16p' "$0"; exit 0 ;;
        *)             die "unknown option: $1" ;;
    esac
    shift
done

# /service/shire is NFS with root_squash: check it as the service account.
as_svc() { setpriv --reuid="$SVC_UID" --regid="$SVC_GID" --clear-groups "$@"; }

[ -d "$DATA_ROOT" ] || die "$DATA_ROOT does not exist; run init.sh first"
as_svc test -d "$BACKUPS/pgbackrest" || die "no pgBackRest repository at $BACKUPS/pgbackrest"

cd "$REPO_DIR"
podman compose build db

run() {  # run <pgbackrest args...> in a one-off container
    podman run --rm --network none -e TZ=America/Los_Angeles \
        --user "$SVC_UID:$SVC_GID" \
        -v "$DATA_ROOT:/var/lib/postgresql" \
        -v "$BACKUPS:/backups" \
        --entrypoint pgbackrest \
        "$IMAGE" --stanza=main "$@"
}

if [ "$mode" = list ]; then
    run info
    exit 0
fi

if podman container exists pg-db && \
   [ "$(podman inspect -f '{{.State.Running}}' pg-db)" = true ]; then
    die "the pg-db container is running; stop it first (podman compose down)"
fi
if [ -n "$(ls -A "$PGDATA_HOST" 2>/dev/null)" ]; then
    die "$PGDATA_HOST is not empty. Restore never overwrites an existing cluster;
       move it aside yourself if you are sure it should be replaced."
fi

as_svc mkdir -p -m 0700 "$PGDATA_HOST"

echo "== Restoring into $PGDATA_HOST =="
run restore "${opts[@]}"

echo
echo "Restore complete. Start the service with:"
echo "  podman compose up -d"
echo "PostgreSQL will replay the remaining WAL and promote; watch progress with:"
echo "  podman logs -f pg-db"
