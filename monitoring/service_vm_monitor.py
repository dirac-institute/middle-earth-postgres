"""Service VM monitor: CPU, memory, disk and load of the VM it runs on.

Serves Prometheus text at http://<vm>:9110/metrics for the gadget monitor
(dirac-institute/middle-earth-gadget-monitor), which polls it every minute.
See README.md in this folder for how to add it to a service.

Every value is read fresh on each request, from files the kernel serves from
memory, so a scrape costs a few milliseconds:

  /proc/stat, /proc/loadavg, /proc/meminfo, /proc/diskstats
      Not namespaced: inside a container they describe the whole VM.
  /sys/block
      Which block devices are real disks.
  /proc/self/mountinfo, statvfs
      The VM's own filesystems, bind-mounted (recursively, read-only) at
      HOST_ROOT. Only local disk filesystems are statted, so a hung NFS
      server can never make a scrape hang.

Standard library only, and nothing in here is specific to one service.
"""

import logging
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("SERVICE_VM_MONITOR_PORT", "9110"))
# "/" works too, to run it outside a container.
HOST_ROOT = os.environ.get("SERVICE_VM_MONITOR_HOST_ROOT", "/host").rstrip("/")

CPU_MODES = ("user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal")
MEMINFO = {"MemTotal": "service_vm_memory_total_bytes",
           "MemFree": "service_vm_memory_free_bytes",
           "MemAvailable": "service_vm_memory_available_bytes",
           "SwapTotal": "service_vm_swap_total_bytes",
           "SwapFree": "service_vm_swap_free_bytes"}
# Disk filesystems only: everything else is virtual (proc, tmpfs, overlay ...),
# remote (nfs, which could hang) or an automounter trigger (autofs).
LOCAL_FS = {"xfs", "ext2", "ext3", "ext4", "btrfs", "zfs"}
SECTOR = 512  # /proc/diskstats counts 512-byte sectors on every device

log = logging.getLogger("service-vm-monitor")


def cpu_and_boot():
    clk = os.sysconf("SC_CLK_TCK")
    out = []
    for line in Path("/proc/stat").read_text().splitlines():
        f = line.split()
        if f[0] == "cpu":
            # Summed over cores; guest time is already counted in user.
            out += [f'service_vm_cpu_seconds_total{{mode="{m}"}} {int(v) / clk}'
                    for m, v in zip(CPU_MODES, f[1:])]
        elif f[0] == "btime":
            out.append(f"service_vm_boot_time_seconds {f[1]}")
    out.append(f"service_vm_cpu_count {os.cpu_count()}")
    return out


def load():
    f = Path("/proc/loadavg").read_text().split()
    return [f"service_vm_load1 {f[0]}", f"service_vm_load5 {f[1]}", f"service_vm_load15 {f[2]}"]


def memory():
    out = []
    for line in Path("/proc/meminfo").read_text().splitlines():
        key, _, rest = line.partition(":")
        if key in MEMINFO:
            out.append(f"{MEMINFO[key]} {int(rest.split()[0]) * 1024}")
    return out


def disks():
    """Whole physical disks: not partitions, loop, device-mapper or removable."""
    out = []
    for line in Path("/proc/diskstats").read_text().splitlines():
        f = line.split()
        dev = f[2]
        blk = Path("/sys/block") / dev
        if not (blk / "device").exists() or (blk / "removable").read_text().strip() == "1":
            continue
        lb = f'{{device="{dev}"}}'
        out += [f"service_vm_disk_reads_total{lb} {f[3]}",
                f"service_vm_disk_read_bytes_total{lb} {int(f[5]) * SECTOR}",
                f"service_vm_disk_writes_total{lb} {f[7]}",
                f"service_vm_disk_written_bytes_total{lb} {int(f[9]) * SECTOR}",
                f"service_vm_disk_io_seconds_total{lb} {int(f[12]) / 1000}"]
    return out


def unescape(path):
    # mountinfo writes space, tab, newline and backslash as octal escapes.
    return (path.replace("\\040", " ").replace("\\011", "\t")
            .replace("\\012", "\n").replace("\\134", "\\"))


def filesystems():
    """Each local filesystem of the VM once, under its shortest mount point.

    A filesystem mounted more than once (bind mounts, as podman makes for its
    own storage) shows up as several mounts of the same device; keep the one
    that mounts the filesystem's root, at the shortest path.
    """
    best = {}
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        pre, _, post = line.partition(" - ")
        f, fstype = pre.split(), post.split()[0]
        devno, root, mnt = f[2], unescape(f[3]), unescape(f[4])
        if fstype not in LOCAL_FS or not (mnt + "/").startswith(HOST_ROOT + "/"):
            continue
        key = (len(root), len(mnt))
        if devno not in best or key < best[devno][0]:
            best[devno] = (key, mnt)
    out = []
    for _, mnt in sorted(best.values(), key=lambda b: b[1]):
        try:
            st = os.statvfs(mnt)
        except OSError as e:
            log.warning("statvfs %s: %s", mnt, e)
            continue
        lb = f'{{mountpoint="{mnt[len(HOST_ROOT):] or "/"}"}}'
        out += [f"service_vm_filesystem_size_bytes{lb} {st.f_blocks * st.f_frsize}",
                f"service_vm_filesystem_avail_bytes{lb} {st.f_bavail * st.f_frsize}",
                f"service_vm_filesystem_files{lb} {st.f_files}",
                f"service_vm_filesystem_files_avail{lb} {st.f_favail}"]
    return out


SOURCES = (cpu_and_boot, load, memory, disks, filesystems)


def collect():
    """Every source that can be read; one failing doesn't hide the others."""
    out = []
    for source in SOURCES:
        try:
            lines = source()
            ok = 1
        except Exception as e:
            log.warning("%s: %r", source.__name__, e)
            lines, ok = [], 0
        out += lines
        out.append(f'service_vm_monitor_source_success{{source="{source.__name__}"}} {ok}')
    return "\n".join(out) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/metrics", "/"):
            self.send_error(404)
            return
        t0 = time.monotonic()
        body = (collect() + f"service_vm_monitor_collect_seconds {time.monotonic() - t0:.4f}\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # one line a minute per poller is just noise


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if not filesystems():
        log.warning("no local filesystems under %s; is / mounted there? "
                    "Filesystem metrics will be missing.", HOST_ROOT)
    log.info("serving on :%d/metrics", PORT)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
