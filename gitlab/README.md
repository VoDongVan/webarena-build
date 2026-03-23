# WebArena GitLab — Setup Guide (Unity HPC)

This directory sets up the **GitLab** environment used by WebArena, adapted to run
under **Apptainer** on UMass Unity HPC. Unity forbids Docker, so the CMU-provided Docker image
(`gitlab-populated-final-port8023.tar`) must be converted to a SIF and run rootlessly.

- **Port:** 8023
- **Apptainer instance name:** `webarena_gitlab`
- **URL:** `http://localhost:8023/explore`
- **Login:** username `root`, password `webarena1234!`

---

## Prerequisites

- You must be on a **compute node** (not a login node): `salloc -p cpu ...`
- Apptainer must be available (pre-installed on Unity)
- `gitlab.sif` must be present (run `download.sh` if not — it builds the SIF from the tar archive)

---

## First-Time Setup

Run **once** per cluster filesystem location:

```bash
bash set_up.sh
```

This does the following in order:

1. Verifies `gitlab.sif` is present
2. Creates `webarena_data/` directory structure
3. Extracts writable data out of the SIF (`/var/opt/gitlab/`, `/etc/gitlab/`, `/var/log/gitlab/`)
4. Pre-patches `external_url` in `gitlab.rb` to `http://localhost:8023`
5. Generates `run_gitlab.sh` and `slurm_gitlab.sh`
6. Performs first boot and runs `gitlab-ctl reconfigure`

All extraction steps are **idempotent** — re-running `set_up.sh` skips steps already done.

> **Note:** Step 3 (data extraction) can take 5–15 minutes. GitLab omnibus is a large image.

---

## Starting GitLab (After Setup)

**Interactive** (current node):
```bash
bash run_gitlab.sh
# Then in a second terminal on the same node:
apptainer exec instance://webarena_gitlab \
  /opt/gitlab/embedded/bin/runsvdir /opt/gitlab/service
```

**SLURM batch job** (recommended — dedicated node, keeps running after you disconnect):
```bash
sbatch slurm_gitlab.sh
```

Check which node the job landed on:
```bash
squeue --me
# or
scontrol show job <jobid> | grep NodeList
```

---

## Stopping GitLab

```bash
# If running interactively:
apptainer instance stop webarena_gitlab

# If running via SLURM:
scancel <jobid>
```

---

## Accessing from Your Local Machine

Once the job is running and you know the node name (e.g. `cpu021`):

```bash
ssh -i ~/.ssh/unity-privkey.key -L 8023:<node-hostname>:8023 vdvo_umass_edu@unity.rc.umass.edu
```

Then open `http://localhost:8023/explore` in your browser.

---

## Directory Layout

```
gitlab/
├── set_up.sh                              # One-time setup script
├── run_gitlab.sh                          # Start script (start instance only)
├── slurm_gitlab.sh                        # SLURM batch wrapper (start + runsvdir foreground)
├── download.sh                            # Builds gitlab.sif from tar archive
├── gitlab.sif                             # Built Apptainer image
├── gitlab-populated-final-port8023.tar    # Source Docker image
├── custom_configs/
│   └── sv_run/                            # Patched runit service run scripts (see below)
└── webarena_data/                         # Extracted writable data (gitignored)
    ├── gitlab_data/                       # /var/opt/gitlab (postgres, redis, repos)
    ├── etc_gitlab/                        # /etc/gitlab (config: gitlab.rb)
    ├── log_gitlab/                        # /var/log/gitlab (service logs)
    ├── run/                               # /run (runtime sockets/pids)
    └── tmp/                               # /tmp
```

---

## Service Stack

Managed by **runit** (`runsvdir`):

| Service | Notes |
|---|---|
| `postgresql` | GitLab's bundled PostgreSQL, socket at `/var/opt/gitlab/postgresql/` |
| `redis` | In-memory cache, socket at `/var/opt/gitlab/redis/redis.socket` |
| `gitlab-workhorse` | HTTP proxy, forwards to Puma via Unix socket |
| `puma` | Rails app server |
| `nginx` | Serves GitLab UI on port 8023 |
| `sidekiq` | Background job processor |
| `gitaly` | Git RPC service |
| `gitlab-kas` | Kubernetes agent server |
| `alertmanager`, `prometheus`, `gitlab-exporter`, `postgres-exporter`, `redis-exporter` | Monitoring stack |

Configuration: `/etc/gitlab/gitlab.rb` (bind-mounted from `webarena_data/etc_gitlab/`)

---

## Issues Encountered and How They Were Fixed

### 1. `%startscript` is empty — runit never launches

**Problem:** Same Docker-conversion artifact as the other WebArena images. `apptainer instance start`
runs `%startscript`, which is empty, so the instance starts but no services launch.

**Fix:** After `apptainer instance start`, explicitly launch runsvdir in the foreground:
```bash
exec apptainer exec instance://webarena_gitlab \
  /opt/gitlab/embedded/bin/runsvdir /opt/gitlab/service
```

Note: use `runsvdir` directly, **not** `runsvdir-start` (see issue #2).

---

### 2. `runsvdir-start` fails — ulimit and `/proc/sys` not permitted on HPC

**Problem:** The `runsvdir-start` wrapper script tries to raise ulimits and write to
`/proc/sys/fs/file-max`. Both fail on HPC with "Operation not permitted" / "Permission denied",
causing the script to exit before it calls `runsvdir`.

**Fix:** Call `runsvdir /opt/gitlab/service` directly, bypassing `runsvdir-start`.

---

### 3. runit `supervise/lock` — read-only filesystem

**Problem:** runit's `runsv` process needs to write `supervise/lock` and `supervise/status`
files inside each service directory (e.g. `/opt/gitlab/sv/nginx/supervise/`). These directories
are inside the read-only SIF.

**Fix:** Add `--writable-tmpfs` to `apptainer instance start`. This overlays an in-memory
writable tmpfs on top of the SIF, allowing runit to write anywhere it needs without enumerating
every service directory.

---

### 4. `chpst: fatal: unable to setgroups` — service run scripts switch users

**Problem:** Every GitLab service run script uses `chpst -u <user>:<user> -U <user>:<user>` to
drop privileges to a service-specific Unix user (`git`, `gitlab-psql`, `gitlab-redis`, etc.).
The `setgroups` syscall this requires is blocked in rootless Apptainer on HPC.

**Fix:** Extract all affected run scripts, remove the `-u` / `-U` flags (and any `chown` lines),
and bind-mount the patched versions back over the originals. The patched scripts live in
`webarena_data/sv_run/` and are bind-mounted in `run_gitlab.sh` as:
```
--bind webarena_data/sv_run/postgresql:/opt/gitlab/sv/postgresql/run
# ... (one line per service)
```

Services patched: `alertmanager`, `gitaly`, `gitlab-exporter`, `gitlab-kas`,
`gitlab-workhorse`, `postgres-exporter`, `postgresql`, `prometheus`, `puma`,
`redis`, `redis-exporter`, `sidekiq`.

Services **not** patched (no user-switching): `logrotate`, `nginx`, `sshd`.

---

### 5. `external_url` hardcoded to CMU hostname

**Problem:** The pre-populated image has an `external_url` pointing to the original deployment
hostname. GitLab uses this URL to generate absolute links and verify requests.

**Fix:** Before first boot, patch `/etc/gitlab/gitlab.rb` (extracted to `webarena_data/etc_gitlab/`):
```bash
sed -i "s|^external_url.*|external_url 'http://localhost:8023'|" webarena_data/etc_gitlab/gitlab.rb
```
Then run `gitlab-ctl reconfigure` inside the running instance to apply the change.

---

### 6. PostgreSQL stale `postmaster.pid`

**Problem:** The extracted PostgreSQL data dir contains a `postmaster.pid` from when it was
running inside Docker during image creation. If this file exists, postgres refuses to start.

**Fix:** Remove `postmaster.pid` before each start:
```bash
rm -f webarena_data/gitlab_data/postgresql/data/postmaster.pid
```

---

### 7. PostgreSQL requires data directory is not group/world-writable

**Problem:** PostgreSQL refuses to start if the data directory has group or world write
permissions.

**Fix:** `chmod 700 webarena_data/gitlab_data/postgresql/data`

---

### 8. `Peer authentication failed for user "gitlab"` — Puma can't connect to PostgreSQL

**Problem:** PostgreSQL's `pg_hba.conf` uses peer authentication for all local connections,
mapped via `pg_ident.conf`. The original mapping only allows OS user `git` to connect as DB
user `gitlab`. Since services now run as the HPC user (`vdvo_umass_edu`) instead of `git`,
Puma's database connection is rejected.

**Fix:** Add a line to `webarena_data/gitlab_data/postgresql/data/pg_ident.conf`:
```
gitlab  vdvo_umass_edu  gitlab
```
Then reload PostgreSQL:
```bash
apptainer exec instance://webarena_gitlab \
  /opt/gitlab/embedded/bin/pg_ctl reload -D /var/opt/gitlab/postgresql/data
```
This is a one-time fix already applied to the extracted data — no action needed on future starts.

---

### 9. Port 8023 — no patching needed

Unlike the shopping (7770/7780) and reddit (9999) environments, GitLab's internal nginx
is already configured to listen on port 8023 in the Docker image. No port patching required.

---

## 502 Bad Gateway Recovery

If GitLab shows HTTP 502 errors after starting, check the logs:

```bash
# Check what puma is doing
tail -30 webarena_data/log_gitlab/puma/current

# Check what workhorse is doing
tail -20 webarena_data/log_gitlab/gitlab-workhorse/current

# Remove stale postgres lock file and restart if postgres crashed
rm -f webarena_data/gitlab_data/postgresql/data/postmaster.pid
apptainer exec instance://webarena_gitlab gitlab-ctl restart postgresql
```
