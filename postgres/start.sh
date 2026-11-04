#!/bin/bash
# Entrypoint for the db container.
#
# 1. Refuse to start unless all five password files are present.
# 2. Start the role/password sync in the background; it waits for the server
#    to accept connections, then makes the roles match the secrets files.
# 3. Hand off to the stock postgres image entrypoint, which runs initdb ONLY
#    if the data directory is empty (no PG_VERSION) and otherwise just starts
#    the server on the existing data.
set -euo pipefail

SECRETS=/run/secrets/postgres
ROLES=(postgres owner readwrite readonly replication)

for role in "${ROLES[@]}"; do
    if [ ! -s "$SECRETS/$role" ]; then
        echo "FATAL: password file $SECRETS/$role is missing or empty." >&2
        echo "On the host: /service/shire/secrets/$role (owned by the service account, mode 0600)." >&2
        echo "Re-running init.sh generates any missing password files." >&2
        exit 1
    fi
done

# Used by the stock entrypoint only when it initializes a brand-new cluster.
# After that, sync-roles.sh is what keeps the postgres password current.
export POSTGRES_PASSWORD_FILE="$SECRETS/postgres"

# Double-fork so the sync is reparented to the container's init (compose
# sets init: true), not to postgres -- see compose.yaml.
( /usr/local/bin/sync-roles.sh & )

exec docker-entrypoint.sh postgres -c config_file=/etc/postgresql/postgresql.conf
