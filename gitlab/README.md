# WebArena GitLab

Runs the WebArena GitLab environment (GitLab Omnibus) as a rootless Apptainer container inside a SLURM job.

- **Port:** 8023
- **Apptainer instance:** `webarena_gitlab`
- **URL:** `http://<node>:8023/`
- **Login:** `root` / `webarena1234!`

---

## Files

| File | Purpose |
|---|---|
| `download.sh` | Converts the Docker tar archive to `gitlab.sif` |
| `set_up.sh` | One-time setup (run after download) |
| `run_gitlab.sh` | Starts the service; called by the SLURM script |
| `slurm_gitlab.sh` | SLURM batch wrapper (submit with `sbatch`) |
| `test_gitlab.sh` | Smoke test |
| `custom_configs/sv_run/` | Patched runit service run scripts (see below) |

---

## First-Time Setup

From a compute node:

```bash
bash download.sh    # converts Docker tar → gitlab.sif (takes ~10 min)
bash set_up.sh      # prepares custom_configs/
```

After setup, start the service with `sbatch slurm_gitlab.sh` or via `bash ../../launch_all.sh`.

---

## How It Starts (run_gitlab.sh)

Each job start extracts a fresh copy of all GitLab data from the read-only SIF to `/tmp` on the compute node's local SSD:

```
/tmp/webarena_runtime_gitlab/
├── gitlab_data/    ← /var/opt/gitlab  (PostgreSQL, Redis, repositories)
├── etc_gitlab/     ← /etc/gitlab       (gitlab.rb config)
├── log_gitlab/     ← /var/log/gitlab   (service logs)
├── run/            ← /run
└── tmp/            ← /tmp
```

After extraction, `run_gitlab.sh`:
1. Fixes PostgreSQL permissions (`chmod 700` on the data dir)
2. Appends the HPC user → `gitlab` mapping to `pg_ident.conf` (see issue #8 below)
3. Patches `external_url` in `gitlab.rb` to `http://<current-node>:8023`
4. Starts the Apptainer instance with all directories bind-mounted
5. Launches `runsvdir` (GitLab's runit service supervisor)
6. Polls `/-/health` up to 60 times (10 min) until GitLab responds HTTP 200
7. Writes `homepage/.gitlab_node` to signal readiness

When the SLURM job ends, a `trap` removes the `/tmp` workspace and stops the instance.

**Why extract to /tmp each time?** scratch3 (NFS) does not support POSIX `fcntl()` locks. PostgreSQL and several GitLab services use file locking; they crash-loop on NFS. The compute node's `/tmp` is local SSD and supports all locking correctly. The fresh extraction also guarantees a clean state on every start.

---

## Service Stack

GitLab Omnibus is managed by **runit** (`runsvdir /opt/gitlab/service`):

| Service | Role |
|---|---|
| `postgresql` | Database (Unix socket only — no TCP conflicts with other services) |
| `redis` | Session cache (port 0, Unix socket) |
| `puma` | Rails application server |
| `gitlab-workhorse` | HTTP proxy between nginx and Puma |
| `nginx` | Serves port 8023 |
| `sidekiq` | Background job processor |
| `gitaly` | Git RPC service |
| `gitlab-kas` | Kubernetes agent server |
| `alertmanager`, `prometheus`, `gitlab-exporter`, `postgres-exporter`, `redis-exporter` | Monitoring |

GitLab uses Unix sockets for PostgreSQL and Redis internally — it has **zero TCP port conflicts** with any other WebArena service and can run on the same node as any of them.

---

## Issues Solved and How

### 1. `%startscript` is empty — runit never launches

The Docker-to-SIF conversion leaves `%startscript` empty. `apptainer instance start` runs `%startscript`, which does nothing, so the instance comes up but no services start.

**Fix:** After `apptainer instance start`, explicitly launch `runsvdir` as a foreground process inside the instance:
```bash
apptainer exec instance://webarena_gitlab \
  /opt/gitlab/embedded/bin/runsvdir -P /opt/gitlab/service &
```

---

### 2. `runsvdir-start` fails — HPC blocks ulimit and `/proc/sys` writes

`runsvdir-start` (the wrapper that runit ships) tries to `ulimit -n` and write `/proc/sys/fs/file-max`. Both are blocked on HPC nodes with "Operation not permitted". The wrapper exits before ever calling `runsvdir`.

**Fix:** Call `runsvdir` directly, bypassing `runsvdir-start`.

---

### 3. runit `supervise/lock` — service directories are read-only

runit's `runsv` needs to write `supervise/lock` and `supervise/status` inside each service dir (e.g. `/opt/gitlab/sv/nginx/supervise/`). These dirs are inside the immutable SIF.

**Fix:** `--writable-tmpfs` on `apptainer instance start`. This overlays an in-memory tmpfs on top of the SIF so runit can write anywhere inside the container without bind-mounting every individual service dir.

---

### 4. `chpst: fatal: unable to setgroups` — service run scripts switch users

Every GitLab runit script uses `chpst -u <user>:<user>` to drop privileges to a service-specific Unix user (`git`, `gitlab-psql`, etc.). The `setgroups` syscall this requires is blocked in rootless Apptainer on HPC.

**Fix:** Extract all affected run scripts, strip the `-u`/`-U` flags, and bind-mount the patched versions from `custom_configs/sv_run/` over the originals. Services patched: `alertmanager`, `gitaly`, `gitlab-exporter`, `gitlab-kas`, `gitlab-workhorse`, `postgres-exporter`, `postgresql`, `prometheus`, `puma`, `redis`, `redis-exporter`, `sidekiq`.

---

### 5. `external_url` hardcoded to CMU hostname

The pre-populated image has `external_url` pointing to CMU's deployment server. GitLab uses this URL for all absolute links and request validation.

**Fix:** Each startup patches `gitlab.rb` to `http://<current-node>:8023` before starting the instance:
```bash
sed -i "s|external_url .*|external_url 'http://$NODE:$PORT'|g" "$WORKSPACE/etc_gitlab/gitlab.rb"
```
No `gitlab-ctl reconfigure` is needed — `run_gitlab.sh` uses a fresh extracted copy on every start.

---

### 6. PostgreSQL stale `postmaster.pid` (historical)

The original setup kept data on NFS. After an unclean shutdown, the stale `postmaster.pid` prevented postgres from starting.

**Resolved by fresh-state design:** Since the data is extracted fresh from the SIF on every start, no stale pid files survive between runs.

---

### 7. PostgreSQL requires 700 permissions on data directory

PostgreSQL refuses to start if the data dir is group- or world-writable.

**Fix:** After extraction, before starting the instance:
```bash
chmod 700 "$WORKSPACE/gitlab_data/postgresql/data"
```

---

### 8. `Peer authentication failed for user "gitlab"` — HPC user ≠ `git`

GitLab's `pg_hba.conf` uses peer authentication. The original `pg_ident.conf` only maps OS user `git` → DB user `gitlab`. Services now run as the HPC user (e.g. `vdvo_umass_edu`), so peer auth fails.

**Fix:** After extraction, append the HPC user mapping before starting:
```bash
echo "gitlab  $USER  gitlab" >> "$WORKSPACE/gitlab_data/postgresql/data/pg_ident.conf"
```
This runs automatically on every start so it works regardless of which HPC user submits the job.

---

### 9. NFS lock failures (historical)

The original setup bind-mounted log and data directories from NFS. `svlogd` (runit's logger) uses `flock()` on log dirs; NFS returns errors for these, causing "unable to lock directory" crash loops in every service.

**Resolved by fresh-state design:** Everything runs from `/tmp` (local SSD). No NFS paths are bind-mounted into the running container.
