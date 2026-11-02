# Deploying the Middle-earth service example to a DiRAC VM

Target: stock Rocky 10 VM on UW DiRAC infrastructure.

The VM provides a reverse proxy that handles TLS termination and routes
traffic to your container on port 8080.

```bash
git clone <this repo> /root/middle-earth-service-example
cd /root/middle-earth-service-example
sudo ./init.sh
podman compose up -d --build
```

Then verify:

```bash
curl http://localhost:8080/api/hello
# {"message":"Hello from Middle-earth!","service":"example"}

curl http://localhost:8080/
# (static HTML page)
```

## What each piece does

| File | Role |
|---|---|
| `service.conf` | Single source of truth for the service account name, uid, and gid. Committed to the repo. Everything else reads from here. |
| `init.sh` | Host-level only: checks the service account matches `service.conf`, installs podman + podman-compose, enables `podman-restart.service`, writes `.env`. Idempotent; safe to re-run. |
| `Dockerfile` | Apache httpd 2.4 + Python 3 + Flask/Gunicorn in one image. Apache serves static files and reverse-proxies `/api/` to Gunicorn. |
| `start.sh` | Container entrypoint: starts Gunicorn in the background, then runs Apache in the foreground. |
| `compose.yaml` | One service: `app` (Apache + Gunicorn in one container on port 8080). |
| `app/server.py` | Flask application with one API endpoint (`GET /api/hello`). |
| `app/static/index.html` | Static HTML page served directly by Apache. |
| `apache/httpd.conf` | Apache virtual host: plain HTTP on 8080, static files from `/srv/static`, `/api/` proxied to Gunicorn on `127.0.0.1:8000`. |
| `start.sh` | Container entrypoint: starts Gunicorn in the background, then runs Apache in the foreground. |
| `dev-startup.sh` | Local development helper: exports environment variables and runs `docker compose` on macOS. |
| `SECRETS.md` | How secrets are stored, the NFS ownership model, and permissions. |

## Architecture

```
                   ┌──────────────────────────────────────────┐
  VM reverse  ──►  │  container                                │
  proxy :8080      │    apache (port 8080)                     │
                   │      /         → static files             │
                   │      /api/*    → gunicorn (port 8000)     │
                   └──────────────────────────────────────────┘
```

## Design choices

**One container, two processes.** Apache and Gunicorn run in the same
container. Apache handles static files and reverse-proxies API requests to
Gunicorn on an internal port. The `start.sh` entrypoint launches Gunicorn in
the background and runs Apache in the foreground as PID 1.

**Containers for everything.** The only things `init.sh` does on the host are
check the service account and install podman. The service account, SSH, and
SELinux are provisioned by IT.
All application logic, dependencies, and configuration live inside the
container image. This means a deployment is fully reproducible from the repo
checkout.

**Secrets are bind-mounted, never baked in.** Any secrets the service needs
are mounted read-only into the container at runtime. See `SECRETS.md` for the
full story.

**Service account with fixed uid/gid.** The service account name, uid, and gid
are defined once in `service.conf` and flow into every other file — init.sh,
the Dockerfile, and compose.yaml all read from it with no fallback defaults.
The uid/gid must match the owner of secrets on the production NFS share, which
is exported with `root_squash` — only that uid can read mode-0600 secrets. See
`SECRETS.md` for details on why this matters.

**Port 8080, localhost only.** The container listens on port 8080 and the
compose file binds it to `127.0.0.1:8080`. The VM's reverse proxy handles
TLS termination and routes external traffic to this port.

## Service identity: `service.conf`

`service.conf` is the single source of truth for the service account:

```
SVC_USER=astro-svc
SVC_UID=1725455
SVC_GID=2121725455
```

It is committed to the repo. `init.sh` reads it, exits if the account does
not exist on the VM with that uid and primary gid, and writes the values into
`.env` alongside the per-host FQDN. The Dockerfile and compose.yaml consume
these values via build args and environment variables with no hardcoded
defaults — if `service.conf` is missing or incomplete, `init.sh` exits
immediately, and running `podman compose` without a populated `.env` will
fail on the missing variables.

## Per-host configuration: `.env`

The only per-machine value is the host's own FQDN, which compose.yaml uses
as the Apache `ServerName` and container hostname. `init.sh` writes it (along
with the `service.conf` values) to `.env`, which podman compose reads
automatically:

```
SVC_USER=astro-svc
SVC_UID=1725455
SVC_GID=2121725455
SVC_FQDN=myhost.astro.washington.edu
```

`.env` is gitignored and must never be copied between hosts.

## VM infrastructure context

DiRAC VMs run Rocky 10 and use podman (not Docker) as the container runtime.
Key things to know:

- **podman-compose** is the compose frontend. It reads the same `compose.yaml`
  format as `docker compose`. Install it from EPEL; `init.sh` handles this.
- **podman-restart.service** must be enabled for `restart: unless-stopped` to
  survive a VM reboot. `init.sh` enables it.
- **The VM's reverse proxy** handles TLS termination and firewall rules.
  The container listens on `127.0.0.1:8080` and does not need to manage TLS or
  open ports itself.
- **SELinux and SSH** are configured by IT. `init.sh` does not touch them.
- **Service accounts** exist because the NFS share uses `root_squash`. The
  container process must run as the uid that owns the secrets on the share.
  IT creates this account on the VM; `init.sh` checks that it matches
  `service.conf` and exits if it does not.

## Rollout to another VM

The procedure above is the whole deployment. On a new VM, confirm:

- The service account in `service.conf` exists on the VM (IT provisions it).
- The VM has network access to pull container base images.
- For production: if the service has secrets, `/service/shire` is mounted and
  the secrets directory is populated (see `SECRETS.md`).

## Boot persistence

`restart: unless-stopped` only survives reboot if `podman-restart.service` is
enabled, which `init.sh` does.
