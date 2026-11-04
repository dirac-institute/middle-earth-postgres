-- Database sizes, as Prometheus text lines.
--
-- Separate from metrics.sql because pg_database_size() looks at every file
-- in the database, so its cost grows with the number of tables and indexes.
-- monitor/exporter.py runs this on the slow (5-minute) schedule; sizes change
-- slowly enough that nothing is lost.

\set ON_ERROR_STOP 1
SET statement_timeout = '120s';

SELECT format('pg_database_size_bytes{datname="%s"} %s',
              replace(replace(datname, '\', '\\'), '"', '\"'), pg_database_size(oid))
  FROM pg_database
 WHERE datallowconn AND NOT datistemplate;
