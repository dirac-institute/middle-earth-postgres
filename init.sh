#!/bin/bash
# Host initialization for a Middle-earth service VM. Run as root; safe to re-run.
#
#   git clone <this repo> && cd middle-earth-service-example
#   sudo ./init.sh
#   podman compose up -d --build
#
# Only host-level concerns live here (podman packages, checking the service
# account, .env). Everything else belongs in the container image. The service
# account, SSH, and SELinux are provisioned by IT; this script does not change
# them.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
CONF_FILE="$REPO_DIR/service.conf"

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

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

# ── Service account ────────────────────────────────────────────────────────
echo "== Service account =="
# The container runs as this uid. On a production VM the secrets directory is
# on a shared NFS mount exported with root_squash, meaning root cannot read
# mode-0600 files -- only the service account can. IT provisions the account;
# the uid/gid in service.conf must match it. See SECRETS.md for the production
# story.
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
    echo "podman and podman-compose already installed"
fi
podman --version

# A compose restart policy only survives reboot if this unit is enabled.
systemctl enable --now podman-restart.service >/dev/null 2>&1 \
    && echo "podman-restart.service enabled" \
    || warn "could not enable podman-restart.service (containers won't restart at boot)"

# ── Compose environment ────────────────────────────────────────────────────
echo
echo "== Compose environment =="
FQDN="$(hostname -f 2>/dev/null || hostname)"
case "$FQDN" in
    *.*) ;;
    *)   warn "hostname '$FQDN' is not fully qualified; check DNS and /etc/hosts" ;;
esac
# Write service identity and the host FQDN into .env so podman compose can
# read them. .env is gitignored and per-host; service.conf is the committed
# source of truth for the identity values.
cat > "$ENV_FILE" <<EOF
SVC_USER=$SVC_USER
SVC_UID=$SVC_UID
SVC_GID=$SVC_GID
SVC_FQDN=$FQDN
EOF
echo "  ok   SVC_USER=$SVC_USER SVC_UID=$SVC_UID SVC_GID=$SVC_GID written to $ENV_FILE"
echo "  ok   SVC_FQDN=$FQDN written to $ENV_FILE"

echo
if [ "$WARNINGS" -gt 0 ]; then
    echo "init complete with $WARNINGS warning(s)."
else
    echo "init complete."
fi
echo "Next: podman compose up -d --build"
