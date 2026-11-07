# Monitoring

Two containers serve Prometheus text metrics for the DiRAC gadget monitor
([middle-earth-gadget-monitor](https://github.com/dirac-institute/middle-earth-gadget-monitor)),
which polls each one every minute from its own VM:

| Container | Endpoint | What | Gadget dashboard | Gadget config |
|---|---|---|---|---|
| `pg-monitor` | `http://<vm fqdn>:9187/metrics` | PostgreSQL and backups (this file) | **Postgres** | `config/postgres.toml` |
| `pg-service-vm` | `http://<vm fqdn>:9110/metrics` | The VM's CPU, memory, disks and load | **Service VMs** | `config/service_vms.toml` |

```bash
curl -s http://localhost:9187/metrics
curl -s http://localhost:9110/metrics
```

Deploying this repo starts both endpoints, but the gadget monitor only polls
VMs listed in its own repo: a new VM needs a pull request there (see
[Registering a VM with the gadget monitor](#registering-a-vm-with-the-gadget-monitor)).

## Registering a VM with the gadget monitor

Do this once per VM, after it is deployed and both endpoints answer. It is a
change to the gadget monitor's repo, not this one.

1. **Check both endpoints from another machine** (from the VM itself is not
   enough: it doesn't show the firewall is open):

   ```bash
   curl -s http://<vm fqdn>:9187/metrics | grep -E '^pg_up|probe_success'
   #   pg_up 1 / pgmon_sizes_probe_success 1 / pgmon_backup_probe_success 1
   curl -s http://<vm fqdn>:9110/metrics | grep -E 'load1 |filesystem_size'
   ```

2. **Open a pull request to
   [middle-earth-gadget-monitor](https://github.com/dirac-institute/middle-earth-gadget-monitor)**
   adding the VM to two files. Use the VM's short hostname (`hostname -s`)
   as `name` in both, so its PostgreSQL and VM graphs line up, and its fully
   qualified name as `address`:

   `config/postgres.toml`:

   ```toml
   [[server]]
   name = "<short hostname>"          # becomes the `server` label; keep it stable
   address = "<vm fqdn>"
   # prefixes = ["<ns>_"]             # only if monitor/custom/ adds metrics
   ```

   `config/service_vms.toml`:

   ```toml
   [[service_vm]]
   name = "<short hostname>"          # becomes the `service_vm` label; keep it stable
   address = "<vm fqdn>"
   ```

   Leave out `port`, `vm_port` and `metrics_url` unless the deployment
   changed them; the defaults (5432, 22, 9187 and 9110) are what this repo
   uses. If the VM is replacing another one (disaster recovery onto a new
   VM, say), change the old entries' `address` and keep their `name`: a
   renamed entry starts new series and the history is left under the old
   name. Check the files first, as an entry may already exist.

   In the PR description, say which repo the VM was deployed from
   (middle-earth-postgres), and paste the output of the two `curl`
   commands above as evidence both endpoints answer from off the VM.

3. **After it merges and the gadget monitor is redeployed** (see that repo's
   README), the VM appears on the **Postgres** and **Service VMs**
   dashboards within a couple of minutes. No dashboard changes are needed.
   If it doesn't, the gadget monitor's own metrics say why:
   `gadget_postgres_exporter_status` and `gadget_service_vm_status` (by
   `status`: `connect_error` usually means a firewall), and
   `gadget_*_lines_dropped` (metric names outside the allowed prefixes).

## The service VM monitor (port 9110)

`monitoring/` is the gadget monitor repo's service VM monitor, copied in
**unchanged**: the same folder goes into every DiRAC service repo. Its own
`monitoring/README.md` documents what it reports and why its settings are
what they are; `compose.yaml` here only adds the build context, the
container name (`pg-service-vm`) and the label. To update it, copy the
folder again from the gadget monitor's repo rather than editing it here.

It differs from the rest of this repo in one way: it **publishes** port 9110
instead of using host networking, so firewalld does not govern it (podman's
DNAT bypasses the zone rules) and `init.sh` opens nothing for it. Anyone who
can reach the VM can read its CPU, memory and disk figures. That is the
gadget monitor's standard choice; `monitoring/README.md` describes how to
restrict it.

## How pg-monitor works

`monitor/exporter.py` (standard-library Python, same image as the db) runs
two collectors in background threads and serves whatever they last
produced. A scrape never waits on PostgreSQL or NFS, so a slow query or a
hung `/service/shire` makes the data stale or missing but never hangs the
endpoint.

| Source | Every | What |
|---|---|---|
| `database` | 60 s (`PGMON_INTERVAL`) | `monitor/metrics.sql` and `monitor/custom/*.sql`, run as `postgres` over the container-local socket; free space on `/data` |
| `sizes` | 300 s (`PGMON_SLOW_INTERVAL`) | `monitor/sizes.sql`: database sizes. `pg_database_size()` looks at every file, so its cost grows with the number of tables and indexes |
| `backups` | 300 s (`PGMON_SLOW_INTERVAL`) | `pgbackrest info`, the backup scheduler's status files and the latest restore-test result (all on `/service/shire`, read-only) |

Nothing walks the data directory or the backup repository, so collection
cost does not grow with the amount of data (apart from database sizes, kept
to every 5 minutes).

When a source fails (PostgreSQL down, shire unreachable), its success metric
goes to 0 (`pg_up`, `pgmon_sizes_probe_success`, `pgmon_backup_probe_success`) and its other metrics are
left out rather than repeated stale. `pgmon_collect_age_seconds{source}`
grows if a collection is stuck. Because the endpoint serves the latest
collection, every value can be up to one interval old: after PostgreSQL
stops, `pg_up` reads 1 until the next database collection.

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
| `pg_database_size_bytes` | Size on disk (every 5 minutes) |
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
| `pgbackrest_backups_repo_bytes` | All retained backups in the repository (compressed). Archived WAL is not included: measuring it would mean walking the repository on NFS |
| `pgbackrest_last_run_{success,timestamp_seconds}{job}` | The scheduler's most recent `backup` and `verify` runs |
| `pgbackrest_restore_test_last_run_timestamp_seconds`, `pgbackrest_restore_test_last_success`, `pgbackrest_restore_test_last_pass_timestamp_seconds` | Automated restore tests (see BACKUP.md) |

**The endpoint itself**

| Metric | Meaning |
|---|---|
| `pgmon_collect_age_seconds{source}`, `pgmon_collect_duration_seconds{source}` | Per source: time since its last collection finished, and how long it took |
| `pgmon_custom_query_success{query}` | Per file in `monitor/custom/` |
| `pgmon_sizes_probe_success` | 1 if the database sizes were read |

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
