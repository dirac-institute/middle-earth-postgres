# Middle-earth PostgreSQL

A template for running a PostgreSQL server on UW DiRAC VM infrastructure,
with continuous backups that can rebuild the database on a brand-new VM from
nothing but the backup and this repository.

One VM runs one PostgreSQL instance: a single database, or a group of
databases that share the same access rules. Access is controlled by who is
assigned the VM (all owners have root), so the in-database access model is
deliberately light: five standard roles, with passwords kept in files.

```bash
git clone <this repo> && cd middle-earth-postgres
sudo ./init.sh
podman compose up -d --build
```

## What you get

- **PostgreSQL 18** in a container, running as the VM's service account,
  listening on the VM's port 5432. Data lives in `/data/postgres`.
- **Five roles** whose passwords come from files in
  `/service/shire/secrets/`. The files are authoritative: edit one and
  recreate the container to change a password.

  | Role          | What it can do |
  |---------------|----------------|
  | `postgres`    | Superuser. |
  | `owner`       | Create databases (and owns what it creates); full DDL in them. |
  | `readwrite`   | Read and write every table in every database. |
  | `readonly`    | Read every table in every database. |
  | `replication` | Streaming replication, e.g. to set up a read replica elsewhere. |

  The framework never creates or drops databases. Make them from inside
  PostgreSQL as `owner` (or `postgres`); `readwrite` and `readonly`
  automatically cover them via the built-in `pg_read_all_data` /
  `pg_write_all_data` roles.
- **pgBackRest backups** to `/service/shire/backups`: continuous WAL
  archiving (point-in-time recovery), a weekly full and nightly block-level
  incremental backups, compression, automatic retention, weekly repository
  verification, and a monthly automated test restore.
- **A monitoring endpoint** on port 9187 (Prometheus text): connections,
  throughput, query timing, database and disk sizes, WAL archiving,
  replication, and backup and restore-test status, polled by the DiRAC
  gadget monitor.

## Connecting

```bash
psql "host=<vm fqdn> port=5432 user=readonly dbname=<db>"
```

Connections are password-authenticated (SCRAM) but **not encrypted** -- there
is no TLS.

To create a database:

```bash
psql "host=<vm fqdn> user=owner dbname=postgres" -c 'CREATE DATABASE mydb'
```

## Documentation

- **`DEPLOY.md`** -- deploying, updating, architecture, design choices, and
  VM infrastructure context.
- **`SECRETS.md`** -- the password files, root_squash, and changing passwords.
- **`BACKUP.md`** -- how backups work, retention, monitoring, restore testing,
  disaster recovery, and major-version upgrades.
- **`MONITORING.md`** -- the metrics endpoint: what it serves and how to add
  deployment-specific metrics.

## What you need from DiRAC infrastructure

- **A Rocky 10 VM** with root, a `/data` partition sized for the database
  (plus WAL headroom), and the service's `/service/shire` NFS share mounted.
- **A service account** created on the VM by IT, matching `service.conf`.
  `/service/shire` is exported with `root_squash`, so only this uid can
  read the secrets and write the backups.
- **Network access** to pull container images during the build.

All of these can be requested from PACS via help-astro@uw.edu. There is a
tracking spreadsheet of all DiRAC services in
[this spreadsheet](https://docs.google.com/spreadsheets/d/14ryGw2b2tsHqK27PX1YHzvvZDDEbCNak8C2At-3fgg8/edit?gid=0#gid=0).
