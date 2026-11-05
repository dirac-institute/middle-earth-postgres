# Stock PostgreSQL 18 plus pgBackRest (and python3 for the monitoring
# endpoint). The db, backup and monitor containers all run this image; they
# differ only in entrypoint and mounts (see compose.yaml).
#
# The major version is pinned by the tag. Physical backups can only be
# restored by the same major version, so changing this tag is a major-version
# upgrade -- see BACKUP.md before touching it.
FROM docker.io/library/postgres:18

RUN apt-get update && \
    apt-get install -y --no-install-recommends pgbackrest jq python3 && \
    rm -rf /var/lib/apt/lists/* /etc/pgbackrest.conf

ARG SVC_UID
ARG SVC_GID
ARG SVC_USER
# Short hostname of the VM this image is built on (from .env, set by init.sh).
# Picks postgres/hosts/<PG_HOSTNAME>.conf; the build fails if it is missing.
ARG PG_HOSTNAME

# A real passwd entry for the service uid: initdb, psql, and pgBackRest all
# look up the current user's name.
RUN groupadd -g ${SVC_GID} ${SVC_USER} && \
    useradd -u ${SVC_UID} -g ${SVC_GID} -M -d /var/lib/postgresql -s /usr/sbin/nologin ${SVC_USER}

COPY postgres/postgresql.conf postgres/pg_hba.conf /etc/postgresql/
COPY postgres/hosts/${PG_HOSTNAME}.conf /etc/postgresql/host.conf
COPY backup/pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY postgres/start.sh postgres/sync-roles.sh \
     backup/scheduler.sh backup/restore-test.sh \
     /usr/local/bin/
COPY monitor/exporter.py monitor/metrics.sql monitor/sizes.sql /usr/local/lib/pgmon/
COPY monitor/custom/ /usr/local/lib/pgmon/custom/
RUN chmod -R a+rX /usr/local/lib/pgmon && \
    chmod 0644 /etc/postgresql/* /etc/pgbackrest/pgbackrest.conf && \
    chmod 0755 /usr/local/bin/start.sh /usr/local/bin/sync-roles.sh \
               /usr/local/bin/scheduler.sh /usr/local/bin/restore-test.sh

ENV PGBACKREST_CONFIG=/etc/pgbackrest/pgbackrest.conf
