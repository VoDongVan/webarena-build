# WebArena Shopping & Shopping Admin: NFS Lock Fixes

## Background

WebArena runs on UMass Unity HPC using **Apptainer** (rootless containers). Compute nodes mount
scratch3 as an NFS filesystem. A fundamental incompatibility exists: **scratch3 NFS does not
support POSIX `fcntl()` file locks**. When a process calls `fcntl(F_SETLK)` on an NFS-backed
file, the kernel returns `EIO` (errno 5) instead of granting or denying the lock.

Multiple services inside the Magento/WebArena containers rely on file locking:

| Service | What it locks | Where |
|---|---|---|
| **InnoDB (MySQL)** | `ibdata1` and data files | `/var/lib/mysql` |
| **PHP-FPM** | Accept lock file | `/tmp` |
| **Redis** | Unix domain socket | `/run/redis/redis.sock` |

When these services start with their data/runtime directories on NFS, they crash immediately on
every start attempt.

---

## Shopping (`webarena_shopping`, port 7770)

### Problems

| Symptom | Root Cause |
|---|---|
| `InnoDB: Unable to lock ./ibdata1 error: 5` | `ibdata1` is on NFS scratch3; `fcntl()` returns EIO |
| `Cannot create lock - I/O error (5)` (PHP-FPM) | Container `/tmp` bind-mounted from NFS; accept lock fails |
| `One can only use the --user switch if running as root` (mysqld) | `mysql.ini` had `--user=mysql`; rootless Apptainer runs as the HPC user, not root |
| PID/socket creation failures | `/var/run` bind-mounted from NFS `webarena_data/run/` |

### Fixes

#### 1. Remove `--user=mysql` from `custom_configs/mysql.ini`

```ini
# Before (broken):
command=mysqld --user=mysql --log-error=/var/log/mysql/error.log

# After (fixed):
command=mysqld --log-error=/var/log/mysql/error.log
```

**Why:** Rootless Apptainer runs as the HPC user. `mysqld` cannot `setuid()` to the `mysql`
system user and exits with status 1 on every attempt.

---

#### 2. Copy MySQL data to local `/tmp` before starting

```bash
MYSQL_LOCAL=/tmp/webarena_mysql_shopping
rm -rf "$MYSQL_LOCAL"
cp -a "$WORKDIR/webarena_data/mysql/." "$MYSQL_LOCAL/"
```

Bind-mount: `--bind $MYSQL_LOCAL:/var/lib/mysql`

**Why:** InnoDB uses `fcntl()` to lock `ibdata1` to prevent two `mysqld` processes from
corrupting the same data files simultaneously. NFS returns EIO for this call. Local `/tmp` is
real disk on the compute node — locking works correctly there.

---

#### 3. Create a local `/var/run` equivalent

```bash
RUN_LOCAL=/tmp/webarena_run_shopping
rm -rf "$RUN_LOCAL"
mkdir -p "$RUN_LOCAL/mysqld" "$RUN_LOCAL/nginx" "$RUN_LOCAL/php-fpm"
chmod 777 "$RUN_LOCAL" "$RUN_LOCAL/mysqld" "$RUN_LOCAL/nginx" "$RUN_LOCAL/php-fpm"
touch "$RUN_LOCAL/mysqld/.init"
```

Bind-mount: `--bind $RUN_LOCAL:/var/run`

**Why:** PID files and Unix sockets in `/var/run` need a lockable filesystem. The `.init`
sentinel file is critical: `docker-entrypoint.sh` checks for it to skip `mysql_install_db`
on already-initialized data. Without it, MySQL tries to reinitialize and fails.

---

#### 4. Create a local container `/tmp`

```bash
TMP_LOCAL=/tmp/webarena_tmp_shopping
rm -rf "$TMP_LOCAL"
mkdir -p "$TMP_LOCAL"
chmod 1777 "$TMP_LOCAL"
```

Bind-mount: `--bind $TMP_LOCAL:/tmp`

**Why:** PHP-FPM creates its accept lock in the container's `/tmp`. The original bind-mount
used `webarena_data/tmp/` on NFS scratch3, causing EIO on every lock attempt.

---

## Shopping Admin (`webarena_shopping_admin`, port 7780)

All four fixes from Shopping apply to Shopping Admin. One additional problem exists.

### Additional Problem: Redis Unix Socket

Shopping Admin binds its runtime directory to `/run` directly (not `/var/run` like Shopping):

```
--bind $RUN_LOCAL:/run
```

Redis is configured to create a Unix socket at `/run/redis/redis.sock`. This subdirectory
must be pre-created in `RUN_LOCAL` before the container starts.

**Error without fix:**
```
Failed opening Unix socket: bind: No such file or directory
```

**Fix:** Add `redis/` to the `mkdir -p` call:

```bash
mkdir -p "$RUN_LOCAL/mysqld" "$RUN_LOCAL/nginx" "$RUN_LOCAL/php-fpm" "$RUN_LOCAL/redis"
chmod 777 "$RUN_LOCAL" "$RUN_LOCAL/mysqld" "$RUN_LOCAL/nginx" "$RUN_LOCAL/php-fpm" "$RUN_LOCAL/redis"
```

**Why Shopping is not affected:** Shopping binds to `/var/run`, leaving `/run` as the
container's native writable overlay. Redis can create `/run/redis/` itself there. Shopping
Admin replaces `/run` entirely with the bind-mount, so the subdirectory must pre-exist.

---

### Startup Race Condition: `cache:flush` May Fail on First Run

`run_shopping_admin.sh` calls `cache:flush` immediately after MySQL becomes ready. On the
first run after a node change, PHP-FPM may not yet be fully ready, causing the flush to
silently fail with "There are no commands defined in the 'cache' namespace."

If the storefront redirects to a stale hostname, run manually:

```bash
apptainer exec instance://webarena_shopping_admin \
  php /var/www/magento2/bin/magento cache:flush
```

---

## Why Local `/tmp` Works

Compute node `/tmp` is local disk or tmpfs — `fcntl()` locking works correctly. NFS scratch3
does not implement the POSIX advisory locking protocol, returning EIO instead.

The copy-to-tmp pattern means:
- A fresh copy of the data is made from NFS to local `/tmp` on each run
- The container reads and writes against the local copy (no lock failures)
- Changes stay in `/tmp` — they are lost when the SLURM job ends
- The NFS copy remains the canonical clean state for the next run

This is intentional for WebArena: the benchmark resets to a known state on each run.

---

## Node Separation Requirement

Shopping and Shopping Admin **cannot run on the same node**. They conflict on:

| Service | Port |
|---|---|
| MySQL | 3306 |
| Elasticsearch | 9200, 9300 |
| Redis | 6379 |
| PHP-FPM | 9000 |

Use `sbatch` with `--exclude=<node>` on the second job to guarantee separate nodes. When
testing interactively, stop one instance before starting the other.

---

## Test Coverage

### `shopping/test_shopping.sh`

Usage: `bash shopping/test_shopping.sh [HOST] [PORT]`
Default port: 7770. HOST auto-detected from `homepage/.shopping_node` if not given.

| Section | What is tested |
|---|---|
| **1. Apptainer instance** | `webarena_shopping` appears in `apptainer instance list` |
| **2. Supervisord** | All 6 services RUNNING: `cron`, `elasticsearch`, `mysqld`, `nginx`, `php-fpm`, `redis-server` |
| **3. MySQL** | Accepts connections; product count >100,000; `web/unsecure/base_url` contains current hostname |
| **4. Redis** | `redis-cli ping` returns PONG |
| **5. Elasticsearch** | Cluster health green or yellow; document count >100,000 |
| **6. HTTP endpoints** | `GET /` (200, body has magento/luma/shopping); category page; search results; product detail; cart; customer login; admin login; `GET /rest/V1/store/storeViews` |
| **7. REST API** | `POST /rest/V1/guest-carts` returns 200 with a cart token |

Expected result: **all tests pass** on a healthy shopping node.

---

### `shopping_admin/test_shopping_admin.sh`

Usage: `bash shopping_admin/test_shopping_admin.sh [HOST] [PORT]`
Default port: 7780. HOST auto-detected from `homepage/.shopping_admin_node` if not given.

| Section | What is tested |
|---|---|
| **1. Apptainer instance** | `webarena_shopping_admin` appears in `apptainer instance list` |
| **2. Supervisord** | All 6 services RUNNING: `cron`, `elasticsearch`, `mysqld`, `nginx`, `php-fpm`, `redis-server` |
| **3. MySQL** | Accepts connections; product count >1,000 (admin dataset has ~2,040); `web/unsecure/base_url` contains current hostname |
| **4. Redis** | `redis-cli ping` returns PONG |
| **5. Elasticsearch** | Cluster health green or yellow; document count >100 (admin dataset has ~181) |
| **6. HTTP endpoints** | Admin root (2xx or 3xx); storefront homepage (200); category page; search results; cart page |
| **7. REST API** | `POST /rest/V1/guest-carts` returns 200 with a cart token |
| **8. Admin REST API** | Bearer token via `POST /rest/V1/integration/admin/token` (admin/admin1234); `GET /rest/V1/store/storeViews` with token; `GET /rest/V1/customers/search` with token; `GET /rest/V1/orders` with token |

Note: The shopping_admin dataset is smaller than shopping (2,040 products vs 104,368; 181 ES
docs vs ~104k). This is expected — it's the CMU-provided admin image.

Expected result: **23/23 tests pass** on a healthy shopping_admin node.
