-- PostgreSQL metrics for the monitoring endpoint, as Prometheus text lines.
--
-- Run by monitor/exporter.py every collection cycle, as postgres over the
-- container-local socket, with `psql -X -At`: every row is one output line.
--
-- Rules (the gadget monitor stores every series for a year):
--   * labels must be bounded: database names, role names, fixed state lists;
--     never PIDs, query text, client addresses or application names
--   * report raw counters (_total) and let the dashboard compute rates
--   * names start with pg_ (the gadget probe only accepts known prefixes)

\set ON_ERROR_STOP 1
SET statement_timeout = '20s';
SET lock_timeout = '1s';

SELECT pg_is_in_recovery() AS in_recovery,
       EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') AS have_pgss
\gset

-- ── Server ──────────────────────────────────────────────────────────────────
SELECT 'pg_server_version_num ' || current_setting('server_version_num');
SELECT 'pg_postmaster_start_time_seconds ' || extract(epoch FROM pg_postmaster_start_time())::bigint;
SELECT 'pg_in_recovery ' || :'in_recovery'::boolean::int;
SELECT 'pg_connections_max ' || current_setting('max_connections');

-- ── Connections (client backends only, not counting this one) ──────────────
SELECT format('pg_connections{state="%s"} %s', s.state, count(a.pid))
  FROM unnest(ARRAY['active', 'idle', 'idle_in_transaction',
                    'idle_in_transaction_aborted', 'other']) AS s(state)
  LEFT JOIN (
      SELECT pid, CASE state
                    WHEN 'active' THEN 'active'
                    WHEN 'idle' THEN 'idle'
                    WHEN 'idle in transaction' THEN 'idle_in_transaction'
                    WHEN 'idle in transaction (aborted)' THEN 'idle_in_transaction_aborted'
                    ELSE 'other' END AS state
        FROM pg_stat_activity
       WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
  ) a USING (state)
 GROUP BY s.state;

-- Roles are bounded: only postgres can create them.
SELECT format('pg_connections_by_user{user="%s"} %s',
              replace(replace(usename, '\', '\\'), '"', '\"'), count(*))
  FROM pg_stat_activity
 WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() AND usename IS NOT NULL
 GROUP BY usename;

-- Longest-running statement and oldest open transaction: a stuck script or a
-- forgotten BEGIN shows up here long before it causes bloat or lock pileups.
SELECT 'pg_longest_query_seconds ' ||
       coalesce(round(max(extract(epoch FROM now() - query_start))::numeric, 1), 0)
  FROM pg_stat_activity
 WHERE backend_type = 'client backend' AND state = 'active' AND pid <> pg_backend_pid();
SELECT 'pg_oldest_transaction_seconds ' ||
       coalesce(round(max(extract(epoch FROM now() - xact_start))::numeric, 1), 0)
  FROM pg_stat_activity
 WHERE backend_type = 'client backend' AND xact_start IS NOT NULL AND pid <> pg_backend_pid();
SELECT 'pg_waiting_on_lock ' || count(*)
  FROM pg_stat_activity
 WHERE backend_type = 'client backend' AND wait_event_type = 'Lock';

-- ── Per database ────────────────────────────────────────────────────────────
-- (Sizes are in sizes.sql, on a slower schedule: pg_database_size() scales
-- with the number of files.)
SELECT format('%s{datname="%s"} %s', m.name,
              replace(replace(d.datname, '\', '\\'), '"', '\"'), m.val)
  FROM pg_database d
  JOIN pg_stat_database s ON s.datid = d.oid
 CROSS JOIN LATERAL (VALUES
      ('pg_database_connections',           s.numbackends::numeric),
      ('pg_database_xact_commit_total',     s.xact_commit),
      ('pg_database_xact_rollback_total',   s.xact_rollback),
      ('pg_database_blks_read_total',       s.blks_read),
      ('pg_database_blks_hit_total',        s.blks_hit),
      ('pg_database_tup_returned_total',    s.tup_returned),
      ('pg_database_tup_fetched_total',     s.tup_fetched),
      ('pg_database_tup_inserted_total',    s.tup_inserted),
      ('pg_database_tup_updated_total',     s.tup_updated),
      ('pg_database_tup_deleted_total',     s.tup_deleted),
      ('pg_database_temp_bytes_total',      s.temp_bytes),
      ('pg_database_deadlocks_total',       s.deadlocks),
      ('pg_database_sessions_total',        s.sessions),
      ('pg_database_active_seconds_total',  round((s.active_time / 1000)::numeric, 3)),
      ('pg_database_xid_age',               age(d.datfrozenxid))
  ) AS m(name, val)
 WHERE d.datallowconn AND NOT d.datistemplate;

-- Statement statistics, summed per database (never per query: unbounded).
-- Entries evicted from pg_stat_statements make these sums drop, which reads
-- as a counter reset; pg_statements_dealloc_total counts evictions.
\if :have_pgss
SELECT format('%s{datname="%s"} %s', m.name,
              replace(replace(d.datname, '\', '\\'), '"', '\"'), m.val)
  FROM (SELECT dbid, sum(calls) AS calls, sum(total_exec_time) AS ms, sum(rows) AS nrows
          FROM pg_stat_statements GROUP BY dbid) p
  JOIN pg_database d ON d.oid = p.dbid
 CROSS JOIN LATERAL (VALUES
      ('pg_statements_calls_total',        p.calls::numeric),
      ('pg_statements_exec_seconds_total', round((p.ms / 1000)::numeric, 3)),
      ('pg_statements_rows_total',         p.nrows::numeric)
  ) AS m(name, val);
SELECT 'pg_statements_dealloc_total ' || dealloc FROM pg_stat_statements_info;
\endif

-- ── WAL and archiving ───────────────────────────────────────────────────────
SELECT 'pg_wal_bytes_total ' || wal_bytes FROM pg_stat_wal;
-- WAL waiting in pg_wal grows without bound if archiving to the backup
-- repository fails.
SELECT 'pg_wal_directory_bytes ' || coalesce(sum(size), 0) FROM pg_ls_waldir();
SELECT 'pg_archiver_archived_total ' || archived_count FROM pg_stat_archiver;
SELECT 'pg_archiver_failed_total ' || failed_count FROM pg_stat_archiver;
SELECT 'pg_archiver_last_archived_timestamp_seconds ' ||
       coalesce(extract(epoch FROM last_archived_time)::bigint, 0) FROM pg_stat_archiver;
SELECT 'pg_archiver_last_failed_timestamp_seconds ' ||
       coalesce(extract(epoch FROM last_failed_time)::bigint, 0) FROM pg_stat_archiver;

-- ── Replication ─────────────────────────────────────────────────────────────
-- As a primary: replicas streaming from us, and slots holding WAL for them.
SELECT 'pg_replication_clients ' || count(*) FROM pg_stat_replication;
SELECT 'pg_replication_max_lag_seconds ' ||
       coalesce(round(max(extract(epoch FROM replay_lag))::numeric, 3), 0)
  FROM pg_stat_replication;
SELECT format('pg_replication_slots{active="%s"} %s', a.active::text, count(s.slot_name))
  FROM unnest(ARRAY[true, false]) AS a(active)
  LEFT JOIN pg_replication_slots s USING (active)
 GROUP BY a.active;
\if :in_recovery
-- As a replica: how far behind the primary we are. The delay also grows when
-- the primary is idle, since it is time since the last replayed commit.
SELECT 'pg_replica_replay_delay_seconds ' ||
       coalesce(round(extract(epoch FROM now() - pg_last_xact_replay_timestamp())::numeric, 1), 0);
SELECT 'pg_wal_receiver_streaming ' || count(*) FROM pg_stat_wal_receiver WHERE status = 'streaming';
\else
SELECT 'pg_replication_max_lag_bytes ' ||
       coalesce(max(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)), 0)
  FROM pg_stat_replication;
SELECT 'pg_replication_slot_max_retained_bytes ' ||
       coalesce(max(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)), 0)
  FROM pg_replication_slots;
\endif
