# Deployment-specific metrics

Put `*.sql` files here to add metrics that only make sense for this
deployment's databases (row counts of a key table, the age of the newest
ingested record, ...). The monitoring endpoint runs each file every minute
and serves its output alongside the standard metrics.

Rules:

- Each row of output is one Prometheus text line: `name{label="value"} 123`.
  Use `psql`-friendly SQL that `SELECT`s those strings (see
  `../metrics.sql` for examples). No timestamps.
- **Prefix every metric with a namespace for this deployment**, e.g. `mpc_`.
  The gadget monitor only imports names with the prefixes listed for this
  server in its `config/postgres.toml`, so add the prefix there too.
- Labels must be bounded: never row IDs, timestamps, or free text. Every
  label combination is stored for a year.
- Keep it cheap: it runs every minute, with a 30 s timeout. Prefer
  catalog estimates (`pg_class.reltuples`) to `count(*)` on big tables.
- A first-line comment `-- database: <name>` picks the database to connect
  to (default `postgres`).

Each file also produces `pgmon_custom_query_success{query="<file name>"}`.

Example, `monitor/custom/mpc_ingest.sql`:

```sql
-- database: mpc
SELECT 'mpc_observations_estimate ' || reltuples::bigint
  FROM pg_class WHERE oid = 'public.observations'::regclass;
SELECT 'mpc_newest_observation_timestamp_seconds ' ||
       coalesce(extract(epoch FROM max(created_at))::bigint, 0)
  FROM public.observations;
```

Files here are baked into the image: rebuild and recreate after changing
them (`podman compose up -d --build --force-recreate`).
