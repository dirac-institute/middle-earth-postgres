#!/bin/bash
# Host initialization for a Middle-earth PostgreSQL VM. Run as root; safe to
# re-run.
#
#   git clone <this repo> && cd middle-earth-postgres
#   sudo ./init.sh
#   podman compose up -d --build
#
# Only host-level concerns live here: checking the service account, podman
# packages, the firewall rule, creating the (empty) directories the
# containers mount, generating any missing password files, and .env.
# Everything else belongs in the container image. The service account, SSH,
# and SELinux are provisioned by IT; this script does not change them.
#
# This script never deletes, overwrites, or chowns existing data: it only
# creates directories and password files that do not exist yet.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
CONF_FILE="$REPO_DIR/service.conf"

DATA_MOUNT=/data
DATA_ROOT=$DATA_MOUNT/postgres
SHIRE=/service/shire
SECRETS=$SHIRE/secrets
BACKUPS=$SHIRE/backups
SCRATCH=$SHIRE/restore-scratch
ROLES=(postgres owner readwrite readonly replication)

if [ ! -f "$CONF_FILE" ]; then
    echo "FATAL: $CONF_FILE not found." >&2
    echo "This file defines SVC_USER, SVC_UID, and SVC_GID for the service account." >&2
    exit 1
fi
# shellcheck source=service.conf
source "$CONF_FILE"
for var in SVC_USER SVC_UID SVC_GID; do
    if [ -z "${!var:-}" ]; then
        echo "FATAL: $var is not set in $CONF_FILE" >&2
        exit 1
    fi
done

WARNINGS=0
warn() { echo "WARNING: $*" >&2; WARNINGS=$((WARNINGS + 1)); }
die()  { echo "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"

# Run a command as the service account. /service/shire is NFS exported with
# root_squash, so root cannot create or read files there -- only this uid can.
as_svc() { setpriv --reuid="$SVC_UID" --regid="$SVC_GID" --clear-groups "$@"; }

# ── Service account ────────────────────────────────────────────────────────
echo "== Service account =="
account_fail() {
    echo "FATAL: $*" >&2
    echo "Fix SVC_USER/SVC_UID/SVC_GID in $CONF_FILE to match the service account" >&2
    echo "on this VM, or request the account from PACS via help-astro@uw.edu." >&2
    exit 1
}
have_user="$(getent passwd "$SVC_USER" || true)"
[ -n "$have_user" ] || account_fail "user $SVC_USER does not exist"
have_uid="$(echo "$have_user" | cut -d: -f3)"
have_gid="$(echo "$have_user" | cut -d: -f4)"
[ "$have_uid" = "$SVC_UID" ] \
    || account_fail "user $SVC_USER has uid $have_uid, service.conf says $SVC_UID"
[ "$have_gid" = "$SVC_GID" ] \
    || account_fail "user $SVC_USER has primary gid $have_gid, service.conf says $SVC_GID"
echo "  ok   user $SVC_USER ($SVC_UID:$SVC_GID) exists"

# ── Packages ────────────────────────────────────────────────────────────────
echo
echo "== Packages =="
need=()
command -v podman >/dev/null || need+=(podman)
command -v podman-compose >/dev/null || need+=(podman-compose)
if [ ${#need[@]} -gt 0 ]; then
    rpm -q epel-release >/dev/null 2>&1 || dnf install -y epel-release
    dnf install -y "${need[@]}"
else
    echo "  ok   podman and podman-compose already installed"
fi
podman --version

# A compose restart policy only survives reboot if this unit is enabled.
systemctl enable --now podman-restart.service >/dev/null 2>&1 \
    && echo "  ok   podman-restart.service enabled" \
    || warn "could not enable podman-restart.service (containers won't restart at boot)"

# ── Firewall ────────────────────────────────────────────────────────────────
echo
echo "== Firewall =="
# The db and monitor containers use host networking, so these rules are what
# let clients on the network reach PostgreSQL (5432) and the metrics (9187).
if systemctl is-active --quiet firewalld; then
    if firewall-cmd --quiet --query-service=postgresql --permanent; then
        echo "  ok   postgresql (5432/tcp) already allowed"
    else
        firewall-cmd --quiet --permanent --add-service=postgresql
        reload=1
        echo "  ok   postgresql (5432/tcp) allowed in the default zone"
    fi
    # The monitoring endpoint (pg-monitor), polled by the gadget monitor.
    if firewall-cmd --quiet --query-port=9187/tcp --permanent; then
        echo "  ok   monitoring endpoint (9187/tcp) already allowed"
    else
        firewall-cmd --quiet --permanent --add-port=9187/tcp
        reload=1
        echo "  ok   monitoring endpoint (9187/tcp) allowed in the default zone"
    fi
    [ -z "${reload:-}" ] || firewall-cmd --quiet --reload
else
    warn "firewalld is not running; ports 5432 and 9187 are not being managed by this script"
fi

# ── Data directory ──────────────────────────────────────────────────────────
echo
echo "== Data directory =="
# Refuse to put the database on the root disk if /data isn't mounted.
mountpoint -q "$DATA_MOUNT" || die "$DATA_MOUNT is not a mount point; the data partition must be mounted"
if [ -d "$DATA_ROOT" ]; then
    owner="$(stat -c %u:%g "$DATA_ROOT")"
    [ "$owner" = "$SVC_UID:$SVC_GID" ] \
        || die "$DATA_ROOT exists but is owned by $owner, not $SVC_UID:$SVC_GID; fix by hand"
    echo "  ok   $DATA_ROOT exists (contents left untouched)"
else
    install -d -m 0700 -o "$SVC_UID" -g "$SVC_GID" "$DATA_ROOT"
    echo "  ok   created $DATA_ROOT"
fi

# ── /service/shire: secrets, backups, restore scratch ───────────────────────
echo
echo "== /service/shire =="
mountpoint -q "$SHIRE" || die "$SHIRE is not mounted"
as_svc test -w "$SHIRE" || die "$SVC_USER cannot write to $SHIRE"

for dir in "$SECRETS:0700" "$BACKUPS:0750" "$SCRATCH:0700"; do
    path="${dir%:*}" mode="${dir#*:}"
    if as_svc test -d "$path"; then
        echo "  ok   $path exists"
    else
        as_svc mkdir -m "$mode" "$path"
        echo "  ok   created $path"
    fi
done

# Password files are authoritative: the db container sets each role's
# password from its file on every start. Generate any that are missing;
# never overwrite an existing one.
for role in "${ROLES[@]}"; do
    f="$SECRETS/$role"
    if as_svc test -s "$f"; then
        perms="$(as_svc stat -c '%a %u' "$f")"
        [ "$perms" = "600 $SVC_UID" ] \
            || warn "$f has mode/owner '$perms'; expected '600 $SVC_UID'"
        echo "  ok   $f exists"
    else
        openssl rand -base64 32 | tr -d '/+=\n' | head -c 32 \
            | as_svc sh -c "umask 077 && cat > '$f'"
        echo "  ok   generated random password in $f"
    fi
done

# ── Compose environment ────────────────────────────────────────────────────
echo
echo "== Compose environment =="
# .env is gitignored and per-host; service.conf is the committed source of
# truth for the identity values.
cat > "$ENV_FILE" <<EOF
SVC_USER=$SVC_USER
SVC_UID=$SVC_UID
SVC_GID=$SVC_GID
EOF
echo "  ok   SVC_USER=$SVC_USER SVC_UID=$SVC_UID SVC_GID=$SVC_GID written to $ENV_FILE"

echo
if [ "$WARNINGS" -gt 0 ]; then
    echo "init complete with $WARNINGS warning(s)."
else
    echo "init complete."
fi
echo "Next: podman compose up -d --build"
echo "Disaster recovery instead? Run ./restore.sh before starting the containers (see BACKUP.md)."
