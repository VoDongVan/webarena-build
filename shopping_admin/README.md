# WebArena Shopping Admin (Magento Admin Panel)

Runs the WebArena Magento 2 admin panel as a rootless Apptainer container inside a SLURM job.

- **Port:** 7780
- **Apptainer instance:** `webarena_shopping_admin`
- **Admin URL:** `http://<node>:7780/admin`
- **Login:** `admin` / `admin1234`

---

## Files

| File | Purpose |
|---|---|
| `download.sh` | Converts the Docker tar archive to `shopping_admin.sif` |
| `set_up.sh` | One-time setup (run after download) |
| `run_shopping_admin.sh` | Starts the service; called by the SLURM script |
| `slurm_shopping_admin.sh` | SLURM batch wrapper (submit with `sbatch`) |
| `test_shopping_admin.sh` | Smoke test |
| `custom_configs/` | Config files bind-mounted over SIF paths at runtime |

---

## First-Time Setup

From a compute node:

```bash
bash download.sh    # converts Docker tar → shopping_admin.sif (10–20 min)
bash set_up.sh      # prepares custom_configs/
```

After setup, start the service with `sbatch slurm_shopping_admin.sh` or via `bash ../../launch_all.sh`.

---

## How It Starts (run_shopping_admin.sh)

Each job start extracts a fresh copy of all state from the read-only SIF to `/tmp` on the compute node's local SSD:

```
/tmp/webarena_runtime_shopping_admin/
├── mysql/              ← /var/lib/mysql
├── esdata/             ← /usr/share/java/elasticsearch/data
├── eslog/              ← /usr/share/java/elasticsearch/logs
├── es_config/          ← /usr/share/java/elasticsearch/config
├── redis/              ← /var/lib/redis
├── magento_var/        ← /var/www/magento2/var    (caches, sessions)
├── magento_generated/  ← /var/www/magento2/generated  (DI interceptors, factories)
├── run/                ← /run
├── tmp/                ← /tmp
├── log/                ← /var/log
└── nginx_tmp/          ← /var/lib/nginx
```

After extraction, `run_shopping_admin.sh`:
1. Extracts and patches the nginx vhost config (`listen 80` → `listen 7780`)
2. Writes a minimal `start.sh` entrypoint that bypasses `docker-entrypoint.sh`
3. Starts the Apptainer instance with all directories bind-mounted
4. Launches supervisord inside the instance
5. Waits for MySQL to accept connections (up to 5 min)
6. Updates the Magento base URL to `http://<current-node>:7780/` in the database
7. Flushes the Magento cache
8. Waits for the storefront (`/`) to return HTTP 2xx
9. **Warms up the admin panel** — hits `/admin/` repeatedly until it responds (up to 10 min)
10. Writes `homepage/.shopping_admin_node` to signal readiness

When the SLURM job ends, a `trap` removes the `/tmp` workspace and stops the instance.

**Why extract to /tmp each time?** scratch3 (NFS) does not support POSIX `fcntl()` locks. InnoDB, Elasticsearch, and PHP-FPM all use file locking that fails with `EIO` on NFS. The compute node's `/tmp` is local SSD and supports locking correctly. Fresh extraction also guarantees a clean state on every start.

---

## Why the Admin Panel Warmup Matters

The first HTTP request to `/admin` triggers Magento's PHP dependency injection code generation if `magento_generated/` was empty or incomplete. This compilation can take **3–8 minutes**. During this time, the admin login form doesn't render — any browser or Playwright agent that navigates to `/admin` immediately will time out waiting for the page.

By extracting `magento_generated/` from the SIF (which contains the pre-compiled DI code) and then pre-hitting `/admin` before writing the `.shopping_admin_node` file, the admin panel is guaranteed to be fully responsive before any agent can reach it.

---

## Service Stack

Managed by **supervisord** (launched via the custom entrypoint):

| Service | Notes |
|---|---|
| `mysql` | MariaDB, listens on `127.0.0.1:3306` |
| `elasticsearch` | Search index, listens on `127.0.0.1:9200` (transport 9300) |
| `redis` | Session/cache store, listens on `127.0.0.1:6379` |
| `php-fpm` | PHP-FPM, listens on `127.0.0.1:9000` |
| `nginx` | Magento web server, listens on port 7780 |

**Port conflict:** Both shopping and shopping_admin use MySQL on 3306 and Elasticsearch on 9200. They **cannot run on the same compute node simultaneously**. `launch_all.sh` handles this automatically.

---

## Issues Solved and How

### 1. `docker-entrypoint.sh` runs `chown mysql:mysql` — requires root

The SIF's runscript calls `/docker-entrypoint.sh`, which does `chown mysql:mysql /var/lib/mysql`. This fails under rootless Apptainer. The symptom is: the instance starts (visible in `apptainer instance list`) but supervisord never launches — only `appinit` appears in `ps`.

**Fix:** Bind-mount a minimal replacement entrypoint:
```bash
# custom_configs/start.sh
exec supervisord -n -c /etc/supervisord.conf
```

---

### 2. Port 80 is privileged — nginx cannot bind

**Fix:** Extract and patch the nginx vhost config on every run:
```bash
apptainer exec $SIF_FILE cat /etc/nginx/conf.d/default.conf > custom_configs/conf_default.conf
sed -i "s/listen 80/listen 7780/g" custom_configs/conf_default.conf
```

---

### 3. Elasticsearch uses `su elastico` — fails without root

**Fix:** `custom_configs/supervisord.conf` calls the ES binary directly, no user switching.

---

### 4. `mysqld --user=mysql` fails without root

The original supervisor config passes `--user=mysql` to `mysqld`, instructing it to drop privileges to the `mysql` OS user. This fails when already running as an unprivileged user.

**Fix:** `custom_configs/supervisord.conf` omits the `--user=mysql` flag.

---

### 5. Magento base URL hardcoded to CMU's server

The database stores `http://metis.lti.cs.cmu.edu:7780/`. The hostname changes with every SLURM job.

**Fix:** On every start, after MySQL is ready:
```bash
mysql -h127.0.0.1 -umagentouser -pMyPassword magentodb -e \
  "UPDATE core_config_data SET value='http://$NODE:7780/' WHERE path LIKE 'web/%base_url%';"
php /var/www/magento2/bin/magento cache:flush
```

---

### 6. nginx temp dirs missing — startup crash

**Fix:** `run_shopping_admin.sh` pre-creates all required nginx temp subdirs before starting the instance.

---

### 7. Magento DI code generation on first `/admin` request — Playwright timeout

If `magento_generated/` is empty, the first `/admin` request triggers PHP's on-demand DI compilation. This takes several minutes. Playwright's `Locator.fill` times out waiting for the login form.

**Fix:** Extract `magento_generated/` from the SIF (pre-compiled DI code) and pre-warm `/admin` before writing the `.shopping_admin_node` readiness file. The warmup loop runs for up to 10 minutes with a 30-second per-request timeout.

---

### 8. NFS lock failures (historical)

InnoDB (`ibdata1`), Elasticsearch (`NativeFSLockFactory`), and PHP-FPM (accept mutex) all crash on NFS due to missing `fcntl()` support.

**Resolved by fresh-state design:** All runtime dirs are under `/tmp` on the local SSD.

---

## Troubleshooting

**Admin panel loads a blank page or 500:** Check supervisord status:
```bash
apptainer exec instance://webarena_shopping_admin supervisorctl status
```

Check the Magento exception log (inside the instance workspace):
```bash
cat /tmp/webarena_runtime_shopping_admin/magento_var/log/exception.log | tail -50
```

**`/admin` redirects to metis.lti.cs.cmu.edu:** The base URL update didn't run. Check the SLURM log — MySQL likely hadn't started. Re-submit the job.
