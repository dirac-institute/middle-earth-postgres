"""Monitoring endpoint for this PostgreSQL server.

Serves Prometheus text at http://<vm>:9187/metrics for the gadget monitor
(dirac-institute/middle-earth-gadget-monitor), which polls it every minute.

Collection runs in background threads and the endpoint only ever returns the
latest cached result, so a slow query or a hung /service/shire mount can make
the data stale or missing but never makes a scrape hang:

  database   every PGMON_INTERVAL s: monitor/metrics.sql plus any
             monitor/custom/*.sql, as postgres over the container-local
             socket; and the free space on /data
  sizes      every PGMON_SLOW_INTERVAL s: monitor/sizes.sql (database sizes,
             whose cost grows with the number of files)
  backups    every PGMON_SLOW_INTERVAL s: `pgbackrest info`, the scheduler's
             status files and the latest restore-test result (all on NFS)

Nothing here walks the data directory or the backup repository, so the cost
of a collection does not grow with the size of the data.

Each source reports its own success (pg_up, pgmon_sizes_probe_success,
pgmon_backup_probe_success). When
a source fails, its other metrics are left out rather than repeated stale.

Standard library only; runs in the same image as the db and backup
containers.
"""

import glob
import json
import logging
import os
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("PGMON_PORT", "9187"))
INTERVAL_S = int(os.environ.get("PGMON_INTERVAL", "60"))
SLOW_INTERVAL_S = int(os.environ.get("PGMON_SLOW_INTERVAL", "300"))

SQL_DIR = Path("/usr/local/lib/pgmon")
CUSTOM_DIR = SQL_DIR / "custom"
DATA_DIR = Path("/var/lib/postgresql")            # /data/postgres, read-only
BACKUPS = Path("/backups")                        # /service/shire/backups, read-only
STATUS_DIR = BACKUPS / "status"
RESTORE_TEST_DIR = BACKUPS / "restore-test"
STANZA = "main"

PSQL_ENV = {**os.environ, "PGHOST": "/var/run/postgresql", "PGUSER": "postgres",
            "PGAPPNAME": "pgmon"}

log = logging.getLogger("pgmon")


def run(cmd, timeout, **kw):
    """Run cmd, return stdout, raise on failure or timeout.

    Never waits on a child that ignores SIGKILL (a process stuck on hung NFS
    can't be killed): on timeout it is abandoned, and the caller's thread
    moves on.
    """
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, **kw)
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        threading.Thread(target=p.wait, daemon=True).start()
        raise TimeoutError(f"{cmd[0]} timed out after {timeout}s")
    if p.returncode != 0:
        raise RuntimeError(f"{cmd[0]} exited {p.returncode}: {err.strip()[-500:]}")
    return out


def psql(sql_file, database="postgres", timeout=30):
    out = run(["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1",
               "-d", database, "-f", str(sql_file)], timeout, env=PSQL_ENV)
    return [line for line in out.splitlines() if line.strip()]


def esc(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


# ── Database ────────────────────────────────────────────────────────────────

def custom_queries():
    """monitor/custom/*.sql: deployment-specific metrics (see the README there)."""
    lines = []
    for f in sorted(CUSTOM_DIR.glob("*.sql")):
        m = re.search(r"^--\s*database:\s*(\S+)", f.read_text(), re.M)
        try:
            lines += psql(f, m[1] if m else "postgres")
            ok = 1
        except Exception as e:
            log.warning("custom query %s failed: %s", f.name, e)
            ok = 0
        lines.append(f'pgmon_custom_query_success{{query="{esc(f.stem)}"}} {ok}')
    return lines


def collect_database():
    try:
        lines = psql(SQL_DIR / "metrics.sql")
        lines.append("pg_up 1")
    except Exception as e:
        log.warning("database metrics failed: %s", e)
        lines = ["pg_up 0"]
    else:
        lines += custom_queries()
    st = os.statvfs(DATA_DIR)
    lines.append(f"pg_data_disk_size_bytes {st.f_blocks * st.f_frsize}")
    lines.append(f"pg_data_disk_free_bytes {st.f_bavail * st.f_frsize}")
    return lines


def collect_sizes():
    try:
        return psql(SQL_DIR / "sizes.sql", timeout=150) + ["pgmon_sizes_probe_success 1"]
    except Exception as e:
        log.warning("database sizes failed: %s", e)
        return ["pgmon_sizes_probe_success 0"]


# ── Backups ─────────────────────────────────────────────────────────────────

def pgbackrest_info():
    info = json.loads(run(["pgbackrest", f"--stanza={STANZA}", "info", "--output=json"], 120))
    stanza = next(s for s in info if s["name"] == STANZA)
    lines = [f'pgbackrest_stanza_status_code {stanza["status"]["code"]}']
    backups = [b for b in stanza.get("backup", []) if not b.get("error")]
    for kind in ("full", "diff", "incr"):
        of_kind = [b for b in backups if b["type"] == kind]
        lines.append(f'pgbackrest_backups{{type="{kind}"}} {len(of_kind)}')
        if not of_kind:
            continue
        last = max(of_kind, key=lambda b: b["timestamp"]["stop"])
        t = last["timestamp"]
        lines += [
            f'pgbackrest_last_backup_timestamp_seconds{{type="{kind}"}} {t["stop"]}',
            f'pgbackrest_last_backup_duration_seconds{{type="{kind}"}} {t["stop"] - t["start"]}',
            # Size of the database at the time of the backup ...
            f'pgbackrest_last_backup_database_bytes{{type="{kind}"}} {last["info"]["size"]}',
            # ... and what this backup added to the repository (compressed).
            f'pgbackrest_last_backup_repo_bytes{{type="{kind}"}} {last["info"]["repository"]["delta"]}',
        ]
    lines.append("pgbackrest_backups_repo_bytes "
                 f'{sum(b["info"]["repository"]["delta"] for b in backups)}')
    return lines


def status_files():
    """The scheduler's last-backup / last-verify files: '<date> OK|FAIL <detail>'."""
    lines = []
    for job in ("backup", "verify"):
        f = STATUS_DIR / f"last-{job}"
        try:
            text, mtime = f.read_text(), f.stat().st_mtime
        except FileNotFoundError:
            continue
        ok = 1 if re.search(r"\bOK\b", text) else 0
        lines += [f'pgbackrest_last_run_success{{job="{job}"}} {ok}',
                  f'pgbackrest_last_run_timestamp_seconds{{job="{job}"}} {int(mtime)}']
    return lines


def restore_tests():
    """restore-test.sh leaves <stamp>-PASS.log / <stamp>-FAIL.log files."""
    logs = sorted(glob.glob(str(RESTORE_TEST_DIR / "*-PASS.log")) +
                  glob.glob(str(RESTORE_TEST_DIR / "*-FAIL.log")))
    if not logs:
        return []
    lines = [f"pgbackrest_restore_test_last_run_timestamp_seconds {int(os.stat(logs[-1]).st_mtime)}",
             f'pgbackrest_restore_test_last_success {1 if logs[-1].endswith("-PASS.log") else 0}']
    passed = [p for p in logs if p.endswith("-PASS.log")]
    if passed:
        lines.append(f"pgbackrest_restore_test_last_pass_timestamp_seconds {int(os.stat(passed[-1]).st_mtime)}")
    return lines


def collect_backups():
    try:
        lines = pgbackrest_info() + status_files() + restore_tests()
        lines.append("pgmon_backup_probe_success 1")
    except Exception as e:
        log.warning("backup metrics failed: %s", e)
        lines = ["pgmon_backup_probe_success 0"]
    return lines


# ── Serving ─────────────────────────────────────────────────────────────────

class Source:
    """One collector, run on its own schedule in its own thread."""

    def __init__(self, name, fn, interval):
        self.name, self.fn, self.interval = name, fn, interval
        self.lines, self.collected_at, self.duration = [], 0.0, 0.0

    def loop(self):
        while True:
            t0 = time.time()
            lines = self.fn()
            self.lines, self.collected_at, self.duration = lines, t0, time.time() - t0
            time.sleep(max(1.0, self.interval - self.duration))

    def render(self, now):
        # A collection that is still stuck shows up as a growing age.
        meta = [f'pgmon_collect_age_seconds{{source="{self.name}"}} {now - self.collected_at:.0f}',
                f'pgmon_collect_duration_seconds{{source="{self.name}"}} {self.duration:.2f}']
        return (self.lines if self.collected_at else []) + meta


SOURCES = [Source("database", collect_database, INTERVAL_S),
           Source("sizes", collect_sizes, SLOW_INTERVAL_S),
           Source("backups", collect_backups, SLOW_INTERVAL_S)]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] != "/metrics":
            self.send_error(404, "try /metrics")
            return
        now = time.time()
        body = ("\n".join(line for s in SOURCES for line in s.render(now)) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass  # one line per scrape would just be noise in podman logs


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s pgmon %(levelname)s %(message)s")
    for s in SOURCES:
        threading.Thread(target=s.loop, name=s.name, daemon=True).start()
    log.info("serving /metrics on port %d (database every %ds, sizes and backups every %ds)",
             PORT, INTERVAL_S, SLOW_INTERVAL_S)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
