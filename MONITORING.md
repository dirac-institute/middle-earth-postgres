# Monitoring

The `pg-monitor` container serves Prometheus text metrics at

```
http://<vm fqdn>:9187/metrics
```

for the DiRAC gadget monitor
([middle-earth-gadget-monitor](https://github.com/dirac-institute/middle-earth-gadget-monitor)),
which polls it every minute from its own VM and graphs it on its **Postgres**
dashboard. To add a server there, add it to that repo's
`config/postgres.toml`.

```bash
curl -s http://localhost:9187/metrics
```

## How it works

`monitor/exporter.py` (standard-library Python, same image as the db) runs
two collectors in background threads and serves whatever they last
produced. A scrape never waits on PostgreSQL or NFS, so a slow query or a
hung `/service/shire` makes the data stale or missing but never hangs the
endpoint.

| Source | Every | What |
|---|---|---|
| `database` | 60 s (`PGMON_INTERVAL`) | `monitor/metrics.sql` and `monitor/custom/*.sql`, run as `postgres` over the container-local socket; free space on `/data` |
| `backups` | 300 s (`PGMON_BACKUP_INTERVAL`) | `pgbackrest info`, the backup scheduler's status files, the latest restore-test result, and `du` of the repository (all on `/service/shire`, read-only) |

When a source fails (PostgreSQL down, shire unreachable), its success metric
goes to 0 (`pg_up`, `pgmon_backup_probe_success`) and its other metrics are
left out rather than repeated stale. `pgmon_collect_age_seconds{source}`
grows if a collection is stuck.

The endpoint has no authentication: the metrics are counts and sizes,
database and role names. `init.sh` opens 9187/tcp in firewalld; to limit it to
the gadget monitor's VM, replace that with a rich rule for its address.

## Metrics

Labels are bounded (database names, role names, fixed lists), because the
gadget monitor keeps every series for a year. Counters end in `_total`; rates
are computed in Grafana.

**Server and connections**

| Metric | Meaning |
|---|---|
| `pg_up` | 1 if the database queries succeeded this cycle |
| `pg_server_version_num`, `pg_postmaster_start_time_seconds`, `pg_in_recovery` | |
| `pg_connections{state}` | Client connections: active, idle, idle_in_transaction, idle_in_transaction_aborted, other |
| `pg_connections_max` | `max_connections` |
| `pg_connections_by_user{user}` | Client connections per role (only roles with connections) |
| `pg_longest_query_seconds` | Age of the longest-running active statement |
| `pg_oldest_transaction_seconds` | Age of the oldest open transaction |
| `pg_waiting_on_lock` | Sessions waiting for a lock |

**Per database** (`datname`; template databases excluded)

| Metric | Meaning |
|---|---|
| `pg_database_size_bytes` | Size on disk |
| `pg_database_connections` | Backends connected |
| `pg_database_{xact_commit,xact_rollback}_total` | Transactions |
| `pg_database_{blks_read,blks_hit}_total` | Blocks read from disk / found in shared buffers |
| `pg_database_tup_{returned,fetched,inserted,updated,deleted}_total` | Rows |
| `pg_database_temp_bytes_total`, `pg_database_deadlocks_total`, `pg_database_sessions_total` | |
| `pg_database_active_seconds_total` | Time spent executing statements |
| `pg_database_xid_age` | Age of the oldest unfrozen transaction ID (wraparound risk) |
| `pg_statements_{calls,exec_seconds,rows}_total` | From `pg_stat_statements`, summed per database: statement count, execution time, rows. Mean statement time = rate(exec_seconds) / rate(calls). The `postgres` database includes the endpoint's own queries |
| `pg_statements_dealloc_total` | Entries evicted from `pg_stat_statements` (makes the sums above drop, read as a counter reset) |

**Disk, WAL and archiving**

| Metric | Meaning |
|---|---|
| `pg_data_disk_{size,free}_bytes` | The `/data` partition |
| `pg_wal_bytes_total` | WAL generated |
| `pg_wal_directory_bytes` | WAL on disk in `pg_wal` (grows if archiving fails) |
| `pg_archiver_{archived,failed}_total` | WAL segments archived to the backup repository / failed attempts |
| `pg_archiver_last_{archived,failed}_timestamp_seconds` | 0 if never. Archiving is currently failing when last_failed > last_archived |

**Replication**

| Metric | Meaning |
|---|---|
| `pg_replication_clients` | Replicas streaming from this server |
| `pg_replication_max_lag_seconds`, `pg_replication_max_lag_bytes` | Largest replay lag among them |
| `pg_replication_slots{active}` | Replication slots, active or not |
| `pg_replication_slot_max_retained_bytes` | Most WAL any slot holds on disk |
| `pg_replica_replay_delay_seconds`, `pg_wal_receiver_streaming` | Only when this server is itself a replica |

**Backups** (pgBackRest repository; every 5 minutes)

| Metric | Meaning |
|---|---|
| `pgmon_backup_probe_success` | 1 if all the backup metrics below were read |
| `pgbackrest_stanza_status_code` | 0 = ok |
| `pgbackrest_backups{type}` | Retained backups: full, diff, incr |
| `pgbackrest_last_backup_timestamp_seconds{type}` | When the most recent backup of each type finished |
| `pgbackrest_last_backup_duration_seconds{type}` | How long it took |
| `pgbackrest_last_backup_database_bytes{type}` | Database size at that backup |
| `pgbackrest_last_backup_repo_bytes{type}` | What that backup added to the repository (compressed) |
| `pgbackrest_backups_repo_bytes` | All retained backups in the repository, without WAL |
| `pgbackrest_repo_bytes` | Everything in the repository, WAL included |
| `pgbackrest_last_run_{success,timestamp_seconds}{job}` | The scheduler's most recent `backup` and `verify` runs |
| `pgbackrest_restore_test_last_run_timestamp_seconds`, `pgbackrest_restore_test_last_success`, `pgbackrest_restore_test_last_pass_timestamp_seconds` | Automated restore tests (see BACKUP.md) |

**The endpoint itself**

| Metric | Meaning |
|---|---|
| `pgmon_collect_age_seconds{source}`, `pgmon_collect_duration_seconds{source}` | Per source: time since its last collection finished, and how long it took |
| `pgmon_custom_query_success{query}` | Per file in `monitor/custom/` |

## Deployment-specific metrics

Add SQL files to `monitor/custom/` for metrics that only make sense for this
deployment's own databases, under their own name prefix. See
`monitor/custom/README.md`. The gadget monitor only imports names with the
`pg_`, `pgbackrest_` and `pgmon_` prefixes plus any listed for this server in
its `config/postgres.toml`.

## Size

About 40 series for the server plus 19 per database (with
`pg_stat_statements`), and a few per connected role. A server with 3
databases is roughly 100 series; sampled every minute that is about 150,000
samples a day in the gadget monitor.
