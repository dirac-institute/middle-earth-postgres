#!/bin/bash
# Host initialization for a Middle-earth PostgreSQL VM. Run as root; safe to
# re-run.
#
#   git clone <this repo> && cd middle-earth-postgres
#   sudo ./init.sh
#   podman compose up -d --build
#
# Only host-level concerns live here: checking the service account (from
# IT's /root/VM.set), finding this host's PostgreSQL config, podman packages,
# the firewall rule, creating the (empty) directories the containers mount,
# generating any missing password files, .env, and reserving huge pages for
# PostgreSQL's shared memory.
# Everything else belongs in the container image. The service account, SSH,
# and SELinux are provisioned by IT; this script does not change them.
#
# This script never deletes, overwrites, or chowns existing data: it only
# creates directories and password files that do not exist yet.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
# Written by IT when the VM is provisioned and authoritative for the service
# account. tcsh syntax: `set VMUSER=astro-mpg`.
VM_SET=/root/VM.set
HOSTS_DIR="$REPO_DIR/postgres/hosts"

DATA_MOUNT=/data
DATA_ROOT=$DATA_MOUNT/postgres
SHIRE=/service/shire
SECRETS=$SHIRE/secrets
BACKUPS=$SHIRE/backups
SCRATCH=$SHIRE/restore-scratch
ROLES=(postgres owner readwrite readonly replication)

WARNINGS=0
warn() { echo "WARNING: $*" >&2; WARNINGS=$((WARNINGS + 1)); }
die()  { echo "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"

# vmset NAME: the value of `set NAME=value` in VM.set, quotes removed. The
# file is parsed, never executed; lines of any other form are ignored.
vmset() {
    sed -n -E "s/^[[:space:]]*set[[:space:]]+$1=(\"([^\"]*)\"|'([^']*)'|([^[:space:]\"']*))[[:space:]]*\$/\2\3\4/p" \
        "$VM_SET" | tail -n 1
}
[ -r "$VM_SET" ] || die "$VM_SET not found. IT writes it when the VM is provisioned; it
       defines the service account (VMUSER, VMUID, VMGID). Ask PACS via help-astro@uw.edu."
SVC_USER="$(vmset VMUSER)"
SVC_UID="$(vmset VMUID)"
SVC_GID="$(vmset VMGID)"
VM_NAME="$(vmset VM)"
[[ "$SVC_USER" =~ ^[a-z_][a-z0-9_.-]*$ ]] || die "VMUSER in $VM_SET is missing or not a user name: '$SVC_USER'"
[[ "$SVC_UID" =~ ^[0-9]+$ ]] || die "VMUID in $VM_SET is missing or not a number: '$SVC_UID'"
[[ "$SVC_GID" =~ ^[0-9]+$ ]] || die "VMGID in $VM_SET is missing or not a number: '$SVC_GID'"

# Run a command as the service account. /service/shire is NFS exported with
# root_squash, so root cannot create or read files there -- only this uid can.
as_svc() { setpriv --reuid="$SVC_UID" --regid="$SVC_GID" --clear-groups "$@"; }

# ── Service account ────────────────────────────────────────────────────────
echo "== Service account =="
account_fail() {
    echo "FATAL: $*" >&2
    echo "$VM_SET and the accounts on this VM disagree; ask PACS via help-astro@uw.edu." >&2
    exit 1
}
have_user="$(getent passwd "$SVC_USER" || true)"
[ -n "$have_user" ] || account_fail "user $SVC_USER does not exist"
have_uid="$(echo "$have_user" | cut -d: -f3)"
have_gid="$(echo "$have_user" | cut -d: -f4)"
[ "$have_uid" = "$SVC_UID" ] \
    || account_fail "user $SVC_USER has uid $have_uid, VM.set says $SVC_UID"
[ "$have_gid" = "$SVC_GID" ] \
    || account_fail "user $SVC_USER has primary gid $have_gid, VM.set says $SVC_GID"
echo "  ok   user $SVC_USER ($SVC_UID:$SVC_GID) from $VM_SET exists"

# ── PostgreSQL host config ─────────────────────────────────────────────────
echo
echo "== PostgreSQL host config =="
# postgres/hosts/<short hostname>.conf is baked into the image and included
# by postgresql.conf. The short name, not the FQDN: mpg, not
# mpg.astro.washington.edu.
PG_HOSTNAME="$(hostname -s | tr '[:upper:]' '[:lower:]')"
[[ "$PG_HOSTNAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "unexpected short hostname '$PG_HOSTNAME'"
HOST_CONF="postgres/hosts/$PG_HOSTNAME.conf"
[ -f "$REPO_DIR/$HOST_CONF" ] || die "no PostgreSQL config for this host: $HOST_CONF
       Create it (copy another host's file and size the memory settings for
       this VM), commit it, and re-run init.sh."
echo "  ok   $HOST_CONF"
[ -z "$VM_NAME" ] || [ "$VM_NAME" = "$PG_HOSTNAME" ] \
    || warn "VM.set says VM=$VM_NAME but the hostname is $PG_HOSTNAME; using the hostname"

# The db container's /dev/shm (parallel query shared memory) may use all of
# the VM's RAM; PostgreSQL's own settings are what limit memory use.
mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
PG_SHM_SIZE="$((mem_kb / 1024))m"
echo "  ok   /dev/shm for the db container: $PG_SHM_SIZE (all RAM)"

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
        # End with a newline so `cat` prints the password on its own line;
        # sync-roles.sh strips it.
        { openssl rand -base64 32 | tr -d '/+=\n' | head -c 32; echo; } \
            | as_svc sh -c "umask 077 && cat > '$f'"
        echo "  ok   generated random password in $f"
    fi
done

# ── Compose environment ────────────────────────────────────────────────────
echo
echo "== Compose environment =="
# .env is gitignored and derived: rewritten on every run from VM.set, the
# hostname and /proc/meminfo.
cat > "$ENV_FILE" <<EOF
# Written by init.sh on every run; don't edit.
SVC_USER=$SVC_USER
SVC_UID=$SVC_UID
SVC_GID=$SVC_GID
PG_HOSTNAME=$PG_HOSTNAME
PG_SHM_SIZE=$PG_SHM_SIZE
EOF
echo "  ok   wrote $ENV_FILE:"
grep -v '^#' "$ENV_FILE" | sed 's/^/         /'

# ── Huge pages ──────────────────────────────────────────────────────────────
echo
echo "== Huge pages =="
# Reserve exactly the huge pages PostgreSQL's shared memory needs
# (shared_buffers plus everything sized from max_connections etc.), so it
# isn't mapped with 4 kB pages whose page tables every connection repeats.
# The count comes from the real config: build the image and ask a throwaway
# server (`postgres -C`), which needs a data directory but not the real one.
# PostgreSQL uses them with huge_pages = try (the default); without them it
# falls back to normal pages. Reserved pages are RAM no one else can use, so
# re-run init.sh after changing memory settings in the host file.
HUGEPAGES_CONF=/etc/sysctl.d/90-postgres-hugepages.conf
build_log="$(mktemp)"
if ! (cd "$REPO_DIR" && podman compose build db) >"$build_log" 2>&1; then
    tail -20 "$build_log" >&2
    rm -f "$build_log"
    die "image build failed (needed to size huge pages)"
fi
rm -f "$build_log"
need_pages="$(podman run --rm --network none --user "$SVC_UID:$SVC_GID" \
    --entrypoint sh middle-earth-postgres/postgres:18 -c '
        initdb -D /tmp/sizing >/dev/null 2>&1 &&
        postgres -D /tmp/sizing -c config_file=/etc/postgresql/postgresql.conf \
                 -c data_directory=/tmp/sizing -C shared_memory_size_in_huge_pages' \
    2>/dev/null)" || true
if [[ "$need_pages" =~ ^[0-9]+$ ]] && [ "$need_pages" -gt 0 ]; then
    page_kb="$(awk '/^Hugepagesize:/ {print $2}' /proc/meminfo)"
    printf '# Written by middle-earth-postgres init.sh: huge pages for PostgreSQL shared memory.\nvm.nr_hugepages = %s\n' \
        "$need_pages" > "$HUGEPAGES_CONF"
    sysctl -q -p "$HUGEPAGES_CONF"
    have_pages="$(awk '/^HugePages_Total:/ {print $2}' /proc/meminfo)"
    if [ "$have_pages" -ge "$need_pages" ]; then
        echo "  ok   vm.nr_hugepages = $need_pages ($((need_pages * page_kb / 1024)) MB) in $HUGEPAGES_CONF"
        echo "       PostgreSQL uses them from its next start"
    else
        warn "asked the kernel for $need_pages huge pages but got $have_pages (memory is fragmented);
       they will all be reserved at the next boot ($HUGEPAGES_CONF)"
    fi
else
    warn "could not compute shared_memory_size_in_huge_pages; huge pages left unchanged"
fi

echo
if [ "$WARNINGS" -gt 0 ]; then
    echo "init complete with $WARNINGS warning(s)."
else
    echo "init complete."
fi
echo "Next: podman compose up -d --build"
echo "Disaster recovery instead? Run ./restore.sh before starting the containers (see BACKUP.md)."
