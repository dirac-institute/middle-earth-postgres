# Deploying Middle-earth PostgreSQL to a DiRAC VM

Target: stock Rocky 10 VM on UW DiRAC infrastructure, with a `/data`
partition and the service's `/service/shire` NFS share mounted.

```bash
git clone <this repo> /root/middle-earth-postgres
cd /root/middle-earth-postgres
sudo ./init.sh
podman compose up -d --build
```

Restoring onto a new VM after losing the old one? Run `./restore.sh` between
`init.sh` and `podman compose up` -- see `BACKUP.md`.

Then verify:

```bash
podman ps                       # pg-db (healthy) and pg-backup, both Up
podman logs pg-db | grep sync-roles
#   sync-roles: roles postgres, owner, readwrite, readonly, replication are in sync ...
podman logs pg-backup | grep scheduler
#   scheduler: ... full backup complete / next backup in ...
```

and from another machine:

```bash
psql "host=$(hostname -f) user=readonly dbname=postgres" -c 'select 1'
```

## Updating

After pulling changes to the repo (or editing `postgresql.conf`,
`pg_hba.conf`, `pgbackrest.conf`, or the scripts, which are all baked into
the image):

```bash
podman compose up -d --build --force-recreate
```

`--force-recreate` matters: podman-compose rebuilds the image on `--build`
but keeps running the old containers unless told to recreate them.

## What each piece does

| File | Role |
|---|---|
| `service.conf` | Single source of truth for the service account name, uid, and gid. |
| `init.sh` | Host-level only: checks the service account, installs podman + podman-compose, enables `podman-restart.service`, opens 5432 in firewalld, creates `/data/postgres` and the `/service/shire` directories, generates missing password files, writes `.env`. Idempotent; never deletes or overwrites anything. |
| `Dockerfile` | `postgres:18` + pgBackRest, the service user, and the config/scripts below. One image for both containers. |
| `compose.yaml` | Two services: `db` (PostgreSQL) and `backup` (pgBackRest scheduler). |
| `postgres/postgresql.conf` | Server configuration: listen on 5432, memory sizing, WAL archiving to pgBackRest. |
| `postgres/pg_hba.conf` | Client authentication: SCRAM passwords for all network logins; replication only for the `replication` role. |
| `postgres/start.sh` | db entrypoint: checks the password files, starts the role sync, hands off to the stock postgres entrypoint. |
| `postgres/sync-roles.sh` | Creates the five roles if missing and sets their passwords from the secrets files. Never drops anything. |
| `backup/pgbackrest.conf` | Backup repository location, retention, compression, async archiving. |
| `backup/scheduler.sh` | backup entrypoint: nightly backups, weekly verify, monthly restore test. |
| `backup/restore-test.sh` | Restores the latest backup to scratch space, replays WAL, checks every database, cleans up. |
| `restore.sh` | Disaster recovery: rebuilds `/data/postgres` from the backup repository. |

## Architecture

```
            network :5432 (firewalld: service "postgresql")
                         │
   ┌─────────────────────▼──────────────┐      ┌──────────────────────────────┐
   │ pg-db   (host network)             │      │ pg-backup   (no network)     │
   │   postgres 18                      │      │   scheduler.sh → pgbackrest  │
   │   archive_command → pgbackrest ────┼──┐   │     backup / verify /        │
   │                                    │  │   │     restore-test             │
   │   unix socket ◄────────────────────┼──┼───┤   (via shared socket volume) │
   └──────┬─────────────────────────────┘  │   └──────┬──────────────┬────────┘
          │ rw                             │          │ ro           │
   /data/postgres  ◄───────────────────────┼──────────┘              │
          (VM disk)                        ▼                         ▼
                              /service/shire/backups   /service/shire/restore-scratch
                                    (NFS, off-VM)
```

## Design choices

**Stock image, minimal additions.** The image is the official `postgres:18`
plus the pgBackRest package. The stock entrypoint handles first-time
`initdb`; it only does so when the data directory has no `PG_VERSION`, so an
existing cluster is never re-initialized.

**Host networking.** PostgreSQL listens directly on the VM's port 5432 and
firewalld decides who can reach it. With a published port instead, podman's
netavark DNATs the traffic and firewalld accepts DNAT'd connections
regardless of zone rules -- the firewall would not actually apply.

**An init process as PID 1** (`init: true`). pgBackRest's async archiver
detaches background processes. Without an init they are reparented to
PostgreSQL, which treats an unknown child exiting non-zero as a crashed
backend and restarts the whole server.

**No databases in the repo.** The framework is agnostic to which databases
exist. Roles are cluster-wide and use PostgreSQL's predefined
`pg_read_all_data` / `pg_write_all_data` roles, so new databases are covered
automatically with no grants to maintain.

**Passwords are files, files are authoritative.** See `SECRETS.md`.

**Backups off the VM, verified by restoring.** See `BACKUP.md`.

**Guards against data loss.** The `/data/postgres` bind source is created by
`init.sh` only after checking `/data` is a mount point; if the partition is
ever missing, the container fails to start instead of initializing an empty
cluster on the root disk. `init.sh` never deletes, overwrites, or recursively
chowns. `restore.sh` refuses to run with the db up or the data directory
non-empty, and pgBackRest itself refuses to restore over files (no `delta`)
or to archive into a repository that belongs to a different cluster.

## Service identity and `.env`

`service.conf` defines `SVC_USER`, `SVC_UID`, `SVC_GID`. `init.sh` checks the
account exists on the VM with exactly those ids and writes them to `.env`,
which podman compose reads. The image is built with a matching user and both
containers run as that uid. `.env` is gitignored and per-host.

## VM infrastructure context

- **podman-compose** (from EPEL, installed by `init.sh`) is the compose
  frontend behind `podman compose`.
- **podman-restart.service** must be enabled for `restart: unless-stopped`
  to survive a reboot. `init.sh` enables it.
- **firewalld**: `init.sh` adds the `postgresql` service (5432/tcp) to the
  default zone. To restrict which networks can connect, replace that with a
  rich rule or a zone with `--add-source` ranges.
- **`/service/shire`** is NFS exported with `root_squash`: root on the VM is
  `nobody` there. Anything that touches it runs as the service account.
- **SELinux** is configured by IT. If it is enforcing, the bind mounts may
  need relabeling (`:Z`) and NFS access may need the `virt_use_nfs` boolean.

## Sizing

`postgresql.conf` is sized for the current VM (8 cores, ~46 GB RAM:
`shared_buffers = 8GB`, `effective_cache_size = 24GB`). Adjust for other VMs.
The db container's `shm_size` in `compose.yaml` (1g) is related: it caps the
`/dev/shm` space parallel queries use, and is explained in a comment there.
`/data` needs room for the database plus WAL that piles up if
`/service/shire` is unreachable (WAL is kept until it has been archived).
