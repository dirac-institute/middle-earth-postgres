# Deploying Middle-earth PostgreSQL to a DiRAC VM

Target: stock Rocky 10 VM on UW DiRAC infrastructure, with a `/data`
partition, the service's `/service/shire` NFS share mounted, and IT's
`/root/VM.set` naming the service account.

**New VM?** It needs `postgres/hosts/<hostname>.conf` (the short hostname, e.g.
`mpg`) in the repo first; `init.sh` stops if it's missing. See
[Per-host configuration](#per-host-configuration).

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
podman ps                       # pg-db (healthy), pg-backup and pg-monitor, all Up
podman logs pg-db | grep sync-roles
#   sync-roles: roles postgres, owner, readwrite, readonly, replication are in sync ...
podman logs pg-backup | grep scheduler
#   scheduler: ... full backup complete / next backup in ...
```

and from another machine:

```bash
psql "host=$(hostname -f) user=readonly dbname=postgres" -c 'select 1'
curl -s http://$(hostname -f):9187/metrics | grep -E '^pg_up|probe_success'
#   pg_up 1 / pgmon_backup_probe_success 1
```

## Updating

After pulling changes to the repo (or editing `postgresql.conf`, this host's
`postgres/hosts/<hostname>.conf`, `pg_hba.conf`, `pgbackrest.conf`, or the
scripts, which are all baked into the image):

```bash
podman compose up -d --build --force-recreate
```

`--force-recreate` matters: podman-compose rebuilds the image on `--build`
but keeps running the old containers unless told to recreate them.

## What each piece does

| File | Role |
|---|---|
| `/root/VM.set` (not in the repo) | Written by IT when the VM is provisioned. The source of truth for the service account name, uid, and gid. |
| `init.sh` | Host-level only: checks the service account against `VM.set`, finds this host's PostgreSQL config, sizes `/dev/shm` from RAM, installs podman + podman-compose, enables `podman-restart.service`, opens 5432 and 9187 in firewalld, creates `/data/postgres` and the `/service/shire` directories, generates missing password files, writes `.env`, reserves huge pages for PostgreSQL's shared memory. Idempotent; never deletes or overwrites anything. |
| `Dockerfile` | `postgres:18` + pgBackRest, the service user, and the config/scripts below. One image for both containers. |
| `compose.yaml` | Three services: `db` (PostgreSQL), `backup` (pgBackRest scheduler) and `monitor` (metrics endpoint). |
| `postgres/postgresql.conf` | Server configuration shared by every host: defaults, then the host file, then the settings the framework depends on (listen on 5432, WAL archiving to pgBackRest, `pg_stat_statements`). |
| `postgres/hosts/<hostname>.conf` | Per-host settings (memory sizing), one file per VM, named by short hostname. |
| `postgres/pg_hba.conf` | Client authentication: SCRAM passwords for all network logins; replication only for the `replication` role. |
| `postgres/start.sh` | db entrypoint: checks the password files, starts the role sync, hands off to the stock postgres entrypoint. |
| `postgres/sync-roles.sh` | Creates the five roles if missing and sets their passwords from the secrets files. Never drops anything. |
| `backup/pgbackrest.conf` | Backup repository location, retention, compression, async archiving. |
| `backup/scheduler.sh` | backup entrypoint: nightly backups, weekly verify, monthly restore test. |
| `backup/restore-test.sh` | Restores the latest backup to scratch space, replays WAL, checks every database, cleans up. |
| `restore.sh` | Disaster recovery: rebuilds `/data/postgres` from the backup repository. |
| `monitor/exporter.py`, `monitor/metrics.sql` | Metrics endpoint on port 9187 for the gadget monitor; see `MONITORING.md`. |
| `monitor/custom/` | Deployment-specific metric queries (empty in the template). |

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

Not drawn: `pg-monitor` (host network, port 9187) reads PostgreSQL over the
same shared socket and the backup repository read-only, and serves metrics
for the gadget monitor (see `MONITORING.md`).

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

IT leaves `/root/VM.set` on every VM, in tcsh syntax:

```
set VM=mpg
set VMUSER=astro-mpg
set VMUID=1734831
set VMGID=2121734831
```

`init.sh` reads `VMUSER`, `VMUID` and `VMGID` (it parses the file and never
runs it), checks the account exists on the VM with exactly those ids, and
writes them to `.env` as `SVC_USER`, `SVC_UID`, `SVC_GID`. The image is built
with a matching user and every container runs as that uid.

`.env` is gitignored and derived: `init.sh` rewrites it on every run, from
`VM.set`, the short hostname (`PG_HOSTNAME`) and the VM's RAM
(`PG_SHM_SIZE`). Re-run `init.sh` rather than editing it.

## Per-host configuration

PostgreSQL settings come from two files, both baked into the image:

- `postgres/postgresql.conf`, shared by every host.
- `postgres/hosts/<hostname>.conf`, for this VM only. `<hostname>` is
  `hostname -s`, lowercased: `mpg`, not `mpg.astro.washington.edu`.
  `init.sh` puts it in `.env` and the build copies that file to
  `/etc/postgresql/host.conf`.

`postgresql.conf` includes the host file partway through. When a setting
appears twice the later one wins, so:

1. **Defaults** come first; the host file can override any of them.
2. **The host file** (memory sizing today).
3. **Framework settings** come after the include, so a host file can't change
   them by accident: listening and `pg_hba.conf`, WAL archiving to pgBackRest,
   `shared_preload_libraries` (for monitoring), and `allow_alter_system = off`.

`ALTER SYSTEM` is turned off because it writes `postgresql.auto.conf`, which
PostgreSQL reads after both files and which would silently override the repo.
Change the files and redeploy instead.

To check where a running setting came from:

```bash
podman exec pg-db psql -U postgres -c \
  "select name, setting, sourcefile from pg_settings where name = 'work_mem'"
```

**Adding a host:** copy an existing file to `postgres/hosts/<hostname>.conf`,
size the memory settings for that VM, and commit it. Without it, `init.sh`
stops with an error, and so would the image build and PostgreSQL itself.

## VM infrastructure context

- **podman-compose** (from EPEL, installed by `init.sh`) is the compose
  frontend behind `podman compose`.
- **podman-restart.service** must be enabled for `restart: unless-stopped`
  to survive a reboot. `init.sh` enables it.
- **firewalld**: `init.sh` adds the `postgresql` service (5432/tcp) and the
  metrics endpoint (9187/tcp) to the default zone. To restrict which networks can connect, replace that with a
  rich rule or a zone with `--add-source` ranges.
- **`/service/shire`** is NFS exported with `root_squash`: root on the VM is
  `nobody` there. Anything that touches it runs as the service account.
- **SELinux** is configured by IT. If it is enforcing, the bind mounts may
  need relabeling (`:Z`) and NFS access may need the `virt_use_nfs` boolean.

## Sizing

Memory is sized per VM in `postgres/hosts/<hostname>.conf` (for mpg, 8 cores
and ~48 GB RAM: `shared_buffers = 12GB`, `effective_cache_size = 36GB`). The db
container's `/dev/shm`, which parallel queries use, is allowed all of the
VM's RAM (`init.sh` sets `PG_SHM_SIZE` from `/proc/meminfo`): it uses memory
only while in use, and PostgreSQL's own settings are what limit memory.

**Huge pages.** `init.sh` builds the image, asks a throwaway server for
`shared_memory_size_in_huge_pages` under the real config, and reserves that
many in `/etc/sysctl.d/90-postgres-hugepages.conf` (6314 x 2 MB on mpg).
PostgreSQL uses them with the default `huge_pages = try`, so it still starts
without them, just with normal pages. Reserved pages are RAM nothing else can
use, so **re-run `init.sh` after changing memory settings** in the host file
(or `max_connections`), then recreate the db container. To check:

```bash
podman exec pg-db psql -U postgres -Atc "show huge_pages_status"   # on
grep HugePages_ /proc/meminfo
```
`/data` needs room for the database plus WAL that piles up if
`/service/shire` is unreachable (WAL is kept until it has been archived).
