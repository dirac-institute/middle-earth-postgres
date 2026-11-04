# Backups and recovery

Backups use [pgBackRest](https://pgbackrest.org). The repository lives in
`/service/shire/backups/pgbackrest` -- on NFS, off the VM. If the VM and its
`/data` disk are lost, the repository plus a clone of this git repo are all
that is needed to rebuild the database on a new VM.

## How it works

**Continuous WAL archiving.** PostgreSQL's `archive_command` hands every
completed WAL segment to `pgbackrest archive-push`, which copies it to the
repository asynchronously (spooling on `/data`, so a slow NFS write never
stalls the server). `archive_timeout = 300` forces a segment at least every
5 minutes, so at most about 5 minutes of committed work can be lost if the VM
dies abruptly. If archiving fails, PostgreSQL keeps the WAL in `pg_wal` and
retries; nothing is lost, but `/data` fills up while the problem persists.

**Base backups**, run by the `pg-backup` container (`backup/scheduler.sh`):

| When (local time) | What |
|---|---|
| First start, if the repository is empty | Full backup |
| Sundays 01:00 | Full backup, then `pgbackrest verify` |
| Other days 01:00 | Incremental backup |
| First Sunday of the month, after the full | Test restore (`restore-test.sh`) |

Configured in `compose.yaml` (`BACKUP_TIME`, `FULL_BACKUP_DAY`,
`RESTORE_TEST`).

Incrementals are **block-level** (`repo1-block`): a changed multi-gigabyte
table file costs only its changed blocks, not the whole file. Everything is
zstd-compressed.

**Retention:** `repo1-retention-full=2` in `backup/pgbackrest.conf`. The
two most recent full backups are kept, with their incrementals and the WAL
needed to replay from them: point-in-time recovery to any moment in roughly
the last 1-2 weeks. Older backups and WAL are deleted automatically after
every backup.

**Size.** Expect the repository to be roughly two compressed full backups
plus one to two weeks of compressed WAL. Typical data compresses 2-4x with
zstd, so for most workloads that is somewhere around 0.6-1.2x the size of
the database; very write-heavy databases generate more WAL and will run
larger. Retention and the full-backup day are one-line changes.

## Checking on backups

```bash
podman exec pg-backup pgbackrest --stanza=main info     # backups, sizes, WAL range
sudo -u $SVC_USER cat /service/shire/backups/status/last-backup
sudo -u $SVC_USER cat /service/shire/backups/status/last-verify
sudo -u $SVC_USER ls /service/shire/backups/restore-test/   # *-PASS.log / *-FAIL.log
podman logs pg-backup
```

Is WAL archiving healthy?

```bash
podman exec pg-db psql -U postgres -h /var/run/postgresql \
    -c 'select archived_count, failed_count, last_archived_wal, last_failed_wal from pg_stat_archiver'
```

Take a backup by hand:

```bash
podman exec pg-backup pgbackrest --stanza=main backup --type=incr   # or full
```

## Restore testing

`backup/restore-test.sh` proves the backups actually restore:

1. Restores the latest backup into `/service/shire/restore-scratch` (with
   its own pgBackRest spool and `archive_mode=off`, so it can never write to
   the repository or interfere with the live server).
2. Starts a throwaway PostgreSQL there with no network listener, replays all
   archived WAL, and waits for it to promote.
3. Connects to every database, lists the roles, and runs `pg_amcheck` (heap
   and B-tree consistency checks) over everything.
4. Stops it, deletes the scratch copy, and writes
   `/service/shire/backups/restore-test/<timestamp>-PASS.log` (or `-FAIL.log`).

It runs monthly after the full backup. Run it by hand at any time:

```bash
podman exec pg-backup restore-test.sh
```

The scratch copy is as large as the database, which is why it goes to the
NFS share rather than `/data`. For a multi-terabyte database expect the test
to take hours (restore, WAL replay, and `pg_amcheck` all scale with size).
Set `RESTORE_TEST_AMCHECK=no` in the backup service's environment to skip the
`pg_amcheck` step.

## Disaster recovery (new VM)

Starting point: a fresh VM with `/data` and the same `/service/shire` share
mounted (if the share is different, copy the old `backups/` and `secrets/`
directories into it first, as the service account).

```bash
git clone <this repo> /root/middle-earth-postgres
cd /root/middle-earth-postgres
sudo ./init.sh                  # creates an empty /data/postgres
sudo ./restore.sh --list        # see what backups exist
sudo ./restore.sh               # latest backup + all archived WAL
podman compose up -d --build
podman logs -f pg-db            # WAL replay, then "database system is ready"
```

On start, PostgreSQL replays the archived WAL, promotes onto a new timeline,
and carries on archiving into the same repository. The role passwords are
re-synced from `/service/shire/secrets/`; if those files were lost too,
`init.sh` generated new ones and those are now the passwords.

### Point-in-time recovery

To undo a mistake (a dropped table, a bad migration), restore to just
before it:

```bash
podman compose down
sudo mv /data/postgres/18/docker /data/postgres/18/docker.broken   # restore never overwrites
sudo ./restore.sh --target-time "2026-11-04 09:30:00-08"
podman compose up -d
```

`--set <label>` restores a specific backup instead (labels from `--list`).

`restore.sh` refuses to run while the db container is up or if the data
directory is not empty. It never deletes or overwrites a cluster -- moving
the old one aside is always a deliberate manual step.

## Major-version upgrades

Physical backups can only be restored by the same PostgreSQL major version
(this is true of every physical backup tool). The major version is pinned by
the image tag in `Dockerfile` (`postgres:18`), so the git history records
which version each backup belongs to: to restore an old backup, check out a
commit with the matching tag.

An upgrade is a deliberate, manual procedure:

1. Take a full backup.
2. Run `pg_upgrade` from the old to the new major version (both versions'
   binaries are needed; e.g. a one-off container from the new image with the
   old binaries installed, against the data in `/data/postgres`).
3. Change the `Dockerfile` tag and the `18` in paths (`pgbackrest.conf`
   `pg1-path`, `restore.sh`), rebuild.
4. `podman exec pg-backup pgbackrest --stanza=main stanza-upgrade`, then take
   a full backup.

The repository keeps working across the upgrade; backups from the old version
stay in it, restorable with the old image, until retention expires them.

## Read replicas

The `replication` role and `pg_hba.conf` allow another PostgreSQL server to
stream from this one (`pg_basebackup -h <this vm> -U replication -R ...`).
Setting up the replica itself is out of scope for this repo.
