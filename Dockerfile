# Stock PostgreSQL 18 plus pgBackRest. Both the db and backup containers run
# this image; they differ only in entrypoint and mounts (see compose.yaml).
#
# The major version is pinned by the tag. Physical backups can only be
# restored by the same major version, so changing this tag is a major-version
# upgrade -- see BACKUP.md before touching it.
FROM docker.io/library/postgres:18

RUN apt-get update && \
    apt-get install -y --no-install-recommends pgbackrest jq && \
    rm -rf /var/lib/apt/lists/* /etc/pgbackrest.conf

ARG SVC_UID
ARG SVC_GID
ARG SVC_USER

# A real passwd entry for the service uid: initdb, psql, and pgBackRest all
# look up the current user's name.
RUN groupadd -g ${SVC_GID} ${SVC_USER} && \
    useradd -u ${SVC_UID} -g ${SVC_GID} -M -d /var/lib/postgresql -s /usr/sbin/nologin ${SVC_USER}

COPY postgres/postgresql.conf postgres/pg_hba.conf /etc/postgresql/
COPY backup/pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY postgres/start.sh postgres/sync-roles.sh \
     backup/scheduler.sh backup/restore-test.sh \
     /usr/local/bin/
RUN chmod 0644 /etc/postgresql/* /etc/pgbackrest/pgbackrest.conf && \
    chmod 0755 /usr/local/bin/start.sh /usr/local/bin/sync-roles.sh \
               /usr/local/bin/scheduler.sh /usr/local/bin/restore-test.sh

ENV PGBACKREST_CONFIG=/etc/pgbackrest/pgbackrest.conf
