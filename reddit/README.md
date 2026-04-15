# WebArena Reddit (Postmill)

Runs the WebArena Reddit environment (Postmill forum software) as a rootless Apptainer container inside a SLURM job.

- **Port:** 9999
- **Apptainer instance:** `webarena_reddit`
- **URL:** `http://<node>:9999/`
- **Login:** `MarvelsGrantMan136` / `test1234`

---

## Files

| File | Purpose |
|---|---|
| `download.sh` | Converts the Docker tar archive to `reddit.sif` |
| `set_up.sh` | One-time setup (run after download) |
| `run_reddit.sh` | Starts the service; called by the SLURM script |
| `slurm_reddit.sh` | SLURM batch wrapper (submit with `sbatch`) |
| `test_reddit.sh` | Smoke test |
| `custom_configs/` | Config files bind-mounted over SIF paths at runtime |

---

## First-Time Setup

From a compute node:

```bash
bash download.sh    # converts Docker tar → reddit.sif
bash set_up.sh      # prepares custom_configs/
```

After setup, start the service with `sbatch slurm_reddit.sh` or via `bash ../../launch_all.sh`.

---

## How It Starts (run_reddit.sh)

Each job start extracts a fresh copy of all state from the read-only SIF to `/tmp` on the compute node's local SSD:

```
/tmp/webarena_runtime_reddit/
├── pgsql/           ← /usr/local/pgsql/data  (PostgreSQL data dir, chmod 700)
├── postmill_var/    ← /var/www/html/var        (Symfony cache / sessions / logs)
├── run/             ← /run and /var/run
└── log/             ← /var/log
```

After extraction, `run_reddit.sh`:
1. Clears the Symfony cache (`postmill_var/cache/`) so PHP doesn't load stale compiled templates
2. Extracts and patches the nginx vhost (`listen 80` → `listen 9999`) and main nginx config (redirects temp paths to `/run/nginx/` subdirs)
3. Writes a minimal `start.sh` entrypoint that bypasses the original `docker-entrypoint.sh`
4. Starts the Apptainer instance with all directories bind-mounted
5. Executes `start.sh` inside the instance (launches supervisord)
6. Polls port 9999 until HTTP 200 or 302 is received
7. Writes `homepage/.reddit_node` to signal readiness

When the SLURM job ends, a `trap` removes the `/tmp` workspace and stops the instance.

**Why extract to /tmp each time?** scratch3 (NFS) does not support POSIX `fcntl()` locks. PHP-FPM creates an accept mutex in `/tmp` using `flock()`; NFS returns `EIO` for these, causing php-fpm to exit 255 on startup. The compute node's `/tmp` is local SSD and supports locking correctly. Fresh extraction also guarantees a clean state on every start.

---

## Service Stack

Managed by **supervisord**:

| Service | Priority | Notes |
|---|---|---|
| `postgres` | 1 | PostgreSQL, Unix socket at `/run/postgresql/.s.PGSQL.5432` |
| `php-fpm` | 2 | PHP-FPM (Symfony/Postmill), listens on `127.0.0.1:9000` |
| `nginx` | 3 | Serves port 9999, proxies PHP via FastCGI |

No TCP port conflicts with any other WebArena service (PostgreSQL uses a Unix socket; PHP-FPM is loopback-only).

---

## Issues Solved and How

### 1. `docker-entrypoint.sh` requires root for `chown` and `su postgres`

The original entrypoint does `chown nginx:nginx /run/nginx` and runs postgres init via `su postgres -c "initdb ..."`. Both require root. Rootless Apptainer does not have root.

**Fix:** Bind-mount a minimal replacement entrypoint (`custom_configs/start.sh`):
```bash
#!/bin/sh
exec supervisord -n -j /supervisord.pid -c /etc/supervisord.conf
```
The PostgreSQL data is already fully initialized inside the SIF, so `initdb` doesn't need to run.

---

### 2. Supervisor config starts postgres via `su postgres`

The default `/etc/supervisor.d/pgsql.ini` runs `su postgres -c "postgres -D ..."`. `su` requires root to switch users.

**Fix:** Bind-mount a patched `custom_configs/pgsql.ini` that runs postgres directly:
```ini
command=postgres -D /usr/local/pgsql/data
```
PostgreSQL only needs read/write access to its data directory — it does not require a specific OS user.

---

### 3. Port 80 is privileged — unprivileged users cannot bind below 1024

nginx in the SIF listens on port 80. Binding privileged ports requires root.

**Fix:** Extract the nginx vhost config, patch `listen 80` → `listen 9999`, and bind-mount the patched version. Done inside `run_reddit.sh` on every start so the patch is always current:
```bash
apptainer exec $SIF_FILE cat /etc/nginx/conf.d/default.conf > custom_configs/conf_default.conf
sed -i "s/listen 80/listen $PORT/g" custom_configs/conf_default.conf
```

---

### 4. nginx temp dirs missing — startup crash

nginx requires `client_body`, `proxy`, `fastcgi`, `uwsgi`, `scgi` temp dirs under its working dir. When `/run` is bind-mounted fresh from `/tmp`, these dirs don't exist.

**Fix:** `run_reddit.sh` pre-creates them before starting the instance:
```bash
mkdir -p "$WORKSPACE/run/nginx/client_body" "$WORKSPACE/run/nginx/proxy" ...
```
The main nginx.conf is also patched to point temp paths to `/run/nginx/` subdirs (the SIF's default `/var/tmp/nginx` doesn't exist).

---

### 5. `%startscript` is empty — supervisord never launches

Docker-to-SIF conversion leaves `%startscript` empty. `apptainer instance start` runs `%startscript`, which does nothing.

**Fix:** After `apptainer instance start`, execute the entrypoint explicitly:
```bash
apptainer exec instance://webarena_reddit /docker-entrypoint.sh &
```

---

### 6. Stale PostgreSQL `postmaster.pid` (historical)

The original setup kept data on NFS. After an unclean shutdown, the stale `postmaster.pid` prevented postgres from restarting.

**Resolved by fresh-state design:** The PostgreSQL data dir is extracted fresh from the SIF on every start. No stale files survive between runs.

---

### 7. Stale Symfony cache causes php-fpm exit 255 (historical)

A PHP session from a prior run could leave compiled Symfony container files in `var/cache/`. On the next start, php-fpm would try to load the stale bytecode and fail.

**Resolved by fresh-state design:** `postmill_var/` is extracted fresh from the SIF, and `run_reddit.sh` clears the cache dir immediately after extraction.

---

### 8. NFS lock failures (historical)

PHP-FPM's accept mutex and PostgreSQL's socket lock both use `flock()`/`fcntl()`. NFS returns `EIO` for these calls, causing both services to fail.

**Resolved by fresh-state design:** All runtime dirs (`/run`, `/tmp`, `/var/log`) are under `/tmp` on the local SSD.
