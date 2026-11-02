# Middle-earth Service Example

A template for deploying containerized services on UW DiRAC VM infrastructure.

This repo is a working "hello world" — Apache serving static files and
reverse-proxying a Python API, all in one container — that demonstrates the
deployment pattern all DiRAC VM services should follow. It is meant to be read
by you *and* by an AI coding assistant. Together, you use it to turn a legacy
service into a standalone repo that deploys the same way.

## What you need before you start

### From DiRAC infrastructure

- **A Rocky 10 VM** to deploy to, with `sudo` access or root login directly.
  The VM provides a reverse proxy that handles TLS termination and routes
  traffic to your container on port 8080.
- **A service account uid/gid**, created on the VM by IT. Your containers
  will run as this identity, and `init.sh` exits if the account on the VM
  does not match `service.conf`.
  On production VMs the service's secrets live on an NFS share exported with
  `root_squash`, so only this uid can read them. If you already have files on
  `/service/shire` for your service, use the uid/gid that owns them. If you
  are starting fresh, coordinate with infrastructure to get one assigned.
- **Network access** from the VM — it needs to pull container base images
  during the build.

All of these can be requested from PACS via help-astro@uw.edu. There is a 
tracking spreadsheet of all DiRAC services in [this spreadsheet](https://docs.google.com/spreadsheets/d/14ryGw2b2tsHqK27PX1YHzvvZDDEbCNak8C2At-3fgg8/edit?gid=0#gid=0)

### From your legacy service

- **SSH access** to the machine where it currently runs.
- **A working understanding of what it does**: what ports it listens on, what
  protocols it speaks, what clients connect to it, what it depends on.
- **Knowledge of where its config and secrets live.** You do not need to have
  fully untangled everything — that is what the AI is for — but you should
  know roughly where to point it.

### An AI coding assistant

This guide assumes you are using an AI agent that can read files, run shell
commands, and write code — something like Claude Code, Cursor, or similar.
The prompts below are written for that kind of tool.

## How this works

The AI reads this example repo to learn the deployment pattern. Then it reads
your legacy service (via SSH, config files you provide, or documentation you
point it at) to understand what your service actually does. It produces a new
standalone repo shaped like this one — its own `service.conf`, `init.sh`,
Dockerfile, compose file, and documentation — but containing your service
instead of the hello-world example.

You stay in the loop for decisions the AI cannot make: which parts of the
legacy setup are load-bearing vs. historical accident, what the service
account should be, where secrets live, and what the service should be called.

## Step by step

### 1. Clone this example repo

Your AI needs to read it. Clone it somewhere accessible:

```bash
git clone <this repo> /path/to/middle-earth-service-example
```

### 2. Gather information about your legacy service

Before prompting the AI, collect (or know where to find) as much of this as
you can. Gaps are okay — the AI can investigate via SSH — but more context up
front means fewer round trips.

- **What the service does** in one or two sentences.
- **What processes run** (`systemctl list-units`, `ps aux`, whatever is
  relevant).
- **What ports it listens on** and what protocols (HTTP, custom TCP, etc.).
- **Where its config files live** (e.g., `/etc/myservice/`, a home directory,
  scattered across `/usr/local`).
- **Where its secrets live** (keys, tokens, credentials) and how they
  get there (manually placed, certbot, puppet, etc.).
- **What packages it depends on** (RPMs, pip packages, system libraries).
- **What it writes** (logs, data, state) and where.
- **How it currently starts** (systemd unit, init script, cron, manually).
- **Whether it needs host networking** or can run behind a port mapping.
- **What OS it runs on** today (RHEL 7, Ubuntu 20.04, etc.).

You do not need all of this in a tidy document. Pointing the AI at the
machine and saying "look at the systemd units and the config directory" is
fine.

### 3. Fill in `service.conf`

Before the AI starts building, decide on the service account identity and
put it in `service.conf`:

```
SVC_USER=my-service-name
SVC_UID=<your assigned uid>
SVC_GID=<your assigned gid>
```

This is the one thing every other file keys off of. There are no fallback
defaults — if this is wrong or missing, everything fails, which is the point.

### 4. Prompt the AI

The prompt below is a starting point. Adjust it based on what you know and
what you want. The key ingredients are:

1. **Point it at this repo** as the pattern to follow.
2. **Point it at the legacy service** so it can understand what to build.
3. **Tell it what the new repo should be called.**
4. **Tell it the service account identity.**

Here is an example prompt:

> I want to containerize [service name] for deployment on UW DiRAC VM
> infrastructure.
>
> **The pattern to follow** is in `/path/to/middle-earth-service-example`.
> Read the entire repo — especially `DEPLOY.md`, `SECRETS.md`, `init.sh`,
> the Dockerfile, and `compose.yaml`. The new repo must deploy the same
> way: clone, `sudo ./init.sh`, `podman compose up -d --build`.
>
> **The legacy service** currently runs on `legacy-host.example.edu`. I have
> SSH access as `myuser`. The service runs as [describe: systemd unit,
> process name, etc.]. Config is in [path]. Secrets (keys, tokens) are in
> [path]. It listens on port [N] for [protocol].
>
> **Build a new standalone repo** called `my-service` in [target directory].
> It should have its own `service.conf` (user: `my-svc`, uid: `NNNNNN`,
> gid: `NNNNNNNNNN`), `init.sh`, Dockerfile, `compose.yaml`, `DEPLOY.md`,
> and `SECRETS.md`, following the same patterns as the example but
> containing my service.
>
> **What to keep from the example patterns:**
> - `init.sh` handles only host-level concerns; everything else is in
>   containers
> - Secrets are bind-mounted read-only, never baked into images
> - `service.conf` is the single source of truth for the service identity
> - The container listens on port 8080; the VM handles TLS and routing
> - Apache for static files and reverse-proxying to the app process
>
> **What to figure out from the legacy service:**
> - What packages and dependencies it needs
> - What config files it uses and what in them is environment-specific vs.
>   universal
> - What secrets it needs and where they should be mounted
> - What it writes (logs, data) and what needs to persist outside the
>   container
> - Whether it needs host networking or can use port mapping
>
> **What NOT to carry over:**
> - Legacy init systems, puppet/ansible config management, or distro-specific
>   workarounds
> - Anything that was there for historical reasons but is not load-bearing
> - The example repo's Python/Flask app — replace it with my actual service

### 5. Iterate

The AI will likely need to SSH into the legacy host to inspect config files,
package lists, and running processes. It may ask you questions about:

- **Ambiguous config:** "This config file has three sections that look
  unused — should I include them?" Trust your knowledge of the service here.
- **Secrets provenance:** "Where does this credential come from? Is it
  renewed automatically?" This determines what goes in `SECRETS.md`.
- **Network topology:** "Does this need to talk to other internal services?
  On what network?" This determines whether you need host networking.
- **State and storage:** "This directory has 200GB of data files — should
  the container see these via a bind mount?" This is a design decision.

### 6. Deploy and test on your VM

Get the new repo onto your DiRAC VM and deploy it:

```bash
git clone <new repo>
cd my-service
sudo ./init.sh
podman compose up -d --build
```

Then verify it actually works. Walk through these checks yourself, or have
the AI do them over SSH to the VM:

1. **Containers are running.** `podman ps` should show all expected
   containers with status `Up`.

2. **No restart loops.** `podman ps` again after 30 seconds — if a
   container's uptime reset, it is crash-looping. Check
   `podman logs <container>` for the error.

3. **The service responds.** Hit the actual endpoint your service exposes —
   API, web UI, protocol-specific client, whatever it is. Confirm you get a
   real response, not a connection refused or a proxy error.

4. **From a remote client.** Repeat step 3 from a machine *outside* the VM
   using the VM's FQDN. This validates that the VM's reverse proxy is routing
   traffic correctly.

5. **Secrets are not baked in.** `podman inspect <container>` — check the
   mounts section shows your secrets directory bind-mounted read-only.
   `podman exec <container> cat /path/to/secret` should work (the mount is
   there), but `podman history <image>` should show no COPY or ADD of
   secret files.

6. **Survives a restart.** `sudo reboot` the VM. After it comes back, check
   that `podman ps` shows the containers running again (this confirms
   `podman-restart.service` is working).

7. **Compare against the legacy service.** If possible, run the same client
   operations against both the legacy host and the new VM. The responses
   should be equivalent. Differences here reveal config or dependencies
   that were missed during containerization.

If any check fails, fix it in the repo (not by hand on the VM), rebuild, and
re-test. The whole point of this pattern is that the repo *is* the
deployment — manual fixes on the host are bugs in the repo.

## Further reading

- **`DEPLOY.md`** — deploy instructions, architecture, design choices, VM
  infrastructure context, and what stays the same vs. what changes per
  service.
- **`SECRETS.md`** — how secrets are handled, the `root_squash` ownership
  story, and permissions.
