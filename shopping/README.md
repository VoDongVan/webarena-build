# WebArena Shopping (Magento Storefront)

Runs the WebArena Magento 2 storefront as a rootless Apptainer container inside a SLURM job.

- **Port:** 7770
- **Apptainer instance:** `webarena_shopping`
- **URL:** `http://<node>:7770/`
- **Login:** `emma.lopez@gmail.com` / `Password.123`

---

## Files

| File | Purpose |
|---|---|
| `download.sh` | Converts the Docker tar archive to `shopping.sif` |
| `set_up.sh` | One-time setup (run after download) |
| `run_shopping.sh` | Starts the service; called by the SLURM script |
| `slurm_shopping.sh` | SLURM batch wrapper (submit with `sbatch`) |
| `test_shopping.sh` | Smoke test |
| `custom_configs/` | Config files bind-mounted over SIF paths at runtime |

---

## First-Time Setup

From a compute node:

```bash
bash download.sh    # converts Docker tar → shopping.sif (10–20 min)
bash set_up.sh      # prepares custom_configs/
```

After setup, start the service with `sbatch slurm_shopping.sh` or via `bash ../../launch_all.sh`.

---

## How It Starts (run_shopping.sh)

Each job start extracts a fresh copy of all state from the read-only SIF to `/tmp` on the compute node's local SSD:

```
/tmp/webarena_runtime_shopping/
├── mysql/              ← /var/lib/mysql
├── esdata/             ← /usr/share/java/elasticsearch/data
├── eslog/              ← /usr/share/java/elasticsearch/logs
├── magento_var/        ← /var/www/magento2/var
├── run/                ← /var/run
├── tmp/                ← /tmp
├── log/                ← /var/log
└── nginx_tmp/          ← /var/lib/nginx  (nginx temp dirs)
```

After extraction, `run_shopping.sh`:
1. Extracts and patches nginx vhost configs (`listen 80` → `listen 7770`)
2. Starts the Apptainer instance (the SIF's `%runscript` launches supervisord automatically)
3. Waits for MySQL to accept connections (up to 5 min)
4. Updates the Magento base URL to `http://<current-node>:7770/` in the database
5. Flushes the Magento cache
6. Writes `homepage/.shopping_node` to signal readiness

When the SLURM job ends, a `trap` removes the `/tmp` workspace and stops the instance.

**Why extract to /tmp each time?** scratch3 (NFS) does not support POSIX `fcntl()` locks. InnoDB uses `fcntl()` on `ibdata1`; Elasticsearch uses `NativeFSLockFactory`; PHP-FPM uses `flock()` for its accept mutex — all return `EIO` on NFS, causing crash-loops. The compute node's `/tmp` is local SSD and supports locking correctly. Fresh extraction also guarantees a clean state on every start.

---

## Service Stack

Managed by **supervisord** (the SIF's `%runscript` starts it):

| Service | Notes |
|---|---|
| `mysql` | MariaDB, listens on `127.0.0.1:3306` |
| `elasticsearch` | Search index, listens on `127.0.0.1:9200` (transport 9300) |
| `php-fpm` | PHP-FPM, listens on `127.0.0.1:9000` |
| `nginx` | Magento web server, listens on port 7770 |
| `cron` | Magento cron jobs |

**Port conflict:** Both shopping and shopping_admin use MySQL on 3306 and Elasticsearch on 9200. They **cannot run on the same compute node simultaneously**. `launch_all.sh` handles this by waiting for shopping's node assignment and submitting shopping_admin with `--exclude=<shopping_node>`.

---

## Issues Solved and How

### 1. SIF is read-only — MySQL, Elasticsearch, Magento need writable storage

Apptainer SIF files are immutable. All stateful directories are extracted to `/tmp` and bind-mounted back at their original paths on every run.

---

### 2. Port 80 is privileged — nginx cannot bind

nginx in the SIF listens on port 80. Rootless Apptainer cannot bind ports below 1024.

**Fix:** Extract and patch both nginx vhost configs on every run:
```bash
apptainer exec $SIF_FILE cat /etc/nginx/conf.d/default.conf > custom_configs/conf_default.conf
sed -i "s/listen 80/listen 7770/g" custom_configs/conf_default.conf
```
The patched files are bind-mounted over the originals inside the container.

---

### 3. Elasticsearch supervisor config uses `su` and wrong binary path

The default supervisor ini runs ES via `su elastico -c ...` (requires root) and uses a relative `elasticsearch` binary name (not on `PATH`).

**Fix:** `custom_configs/elasticsearch.ini` overrides the supervisor program to call the binary directly without user switching:
```ini
[program:elasticsearch]
command=/usr/share/java/elasticsearch/bin/elasticsearch
environment=ES_JAVA_HOME=/usr,ES_JAVA_OPTS="-Xms512m -Xmx512m"
```

---

### 4. nginx temp dirs missing — startup crash

nginx requires `client_body`, `proxy`, `fastcgi`, `uwsgi`, `scgi` subdirs under `/var/lib/nginx`. When that directory is bind-mounted fresh from `/tmp`, these subdirs don't exist.

**Fix:** `run_shopping.sh` pre-creates all required subdirs before starting the instance:
```bash
mkdir -p "$WORKSPACE/nginx_tmp/tmp/client_body" "$WORKSPACE/nginx_tmp/tmp/proxy" ...
```

---

### 5. Magento base URL hardcoded to CMU's server

The Magento database stores `http://metis.lti.cs.cmu.edu:7770/` as the base URL. Since the hostname changes with each SLURM job, this must be updated on every start.

**Fix:** After MySQL is ready, `run_shopping.sh` updates the URL and flushes the cache:
```bash
mysql -h127.0.0.1 -umagentouser -pMyPassword magentodb -e \
  "UPDATE core_config_data SET value='http://$NODE:7770/' WHERE path LIKE 'web/%base_url%';"
php /var/www/magento2/bin/magento cache:flush
```

---

### 6. MySQL `.init` marker

The SIF's docker-entrypoint checks for `/var/run/mysqld/.init` to determine whether MySQL is already initialized. `run_shopping.sh` creates this marker file in the `/tmp` workspace before starting the container, preventing the entrypoint from running `mysql_install_db` on an already-initialized data dir.

---

### 7. NFS lock failures (historical)

The original setup kept MySQL, Elasticsearch, and runtime dirs on NFS. InnoDB returned `EIO` on `ibdata1` locks; ES crash-looped with `IOException`; PHP-FPM exited 255 with `EIO` on its accept mutex.

**Resolved by fresh-state design:** All runtime dirs are under `/tmp` on the local SSD.

---

## Troubleshooting

**500 Internal Server Error:** Check supervisord status inside the instance:
```bash
apptainer exec instance://webarena_shopping supervisorctl status
```

**Category pages show no products:** Elasticsearch is still warming up. Wait 30s and reindex:
```bash
apptainer exec instance://webarena_shopping \
  php /var/www/magento2/bin/magento indexer:reindex catalogsearch_fulltext
```

**Redirecting to metis.lti.cs.cmu.edu:** The base URL update didn't run. Check the SLURM log — MySQL likely hadn't started yet. Re-submit the job.
