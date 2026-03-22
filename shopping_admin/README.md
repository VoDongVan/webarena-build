# WebArena Shopping Admin — Setup Guide (Unity HPC)

This directory sets up the **Magento 2 admin panel** environment used by WebArena, adapted to run
under **Apptainer** on UMass Unity HPC. Unity forbids Docker, so the CMU-provided Docker image
(`shopping_admin_final_0719.tar`) must be converted to a SIF and run rootlessly.

- **Port:** 7780
- **Apptainer instance name:** `webarena_shopping_admin`
- **Admin URL:** `http://localhost:7780/admin`

---

## Prerequisites

- You must be on a **compute node** (not a login node): `salloc -p cpu ...`
- Apptainer must be available: `module load apptainer` if needed
- `shopping_admin_final_0719.tar` must be present (run `download.sh` if not)

---

## First-Time Setup

Run **once** per cluster filesystem location:

```bash
bash set_up.sh
```

This does the following in order:

1. Builds `shopping_admin.sif` from the Docker tar archive (10–20 min)
2. Creates `webarena_data/` and `custom_configs/` directory structures
3. Extracts writable data out of the SIF (MySQL, Elasticsearch, Redis, Magento var/generated)
4. Generates patched config files (nginx port, supervisord, start.sh entrypoint bypass)
5. Generates `run_shopping_admin.sh`
6. Boots the instance for the first time
7. Patches the Magento base URL from CMU's server to `localhost:7780`, flushes cache, reindexes

All extraction steps are **idempotent** — re-running `set_up.sh` skips steps already done.

---

## Starting the Site (After Setup)

From the same directory on any compute node:

```bash
bash run_shopping_admin.sh
```

---

## Stopping the Site

```bash
apptainer instance stop webarena_shopping_admin
```

---

## Accessing from Your Local Machine

The site listens on `localhost:7780` inside the cluster. Use an SSH tunnel:

```bash
ssh -L 7780:<node-hostname>:7780 <your-username>@unity.rc.umass.edu
```

Get the current node hostname with `hostname` while on the compute node. Then open:

- Storefront: `http://localhost:7780/`
- Admin panel: `http://localhost:7780/admin`

---

## Issues Encountered and How They Were Fixed

### 1. SIF is read-only — MySQL, Elasticsearch, and Magento need writable storage

**Problem:** Apptainer SIF files are immutable. MySQL, Elasticsearch, Redis, and Magento's
`var/` and `generated/` directories all require write access at runtime.

**Fix:** Extract those directories out of the SIF once into `webarena_data/`, then bind-mount
them back into the container at their original paths on every run:

```
--bind $(pwd)/webarena_data/mysql:/var/lib/mysql
--bind $(pwd)/webarena_data/esdata:/usr/share/java/elasticsearch/data
...
```

**Why this way:** Bind mounts let the container see the paths at their expected locations while
the actual files live on the writable host filesystem. This is the standard Apptainer pattern
for stateful services.

---

### 2. `docker-entrypoint.sh` runs `chown mysql:mysql` which requires root

**Problem:** The SIF's runscript calls `/docker-entrypoint.sh` before starting `supervisord`.
That script does `chown mysql:mysql /var/lib/mysql`, which fails under rootless Apptainer
(no `root` privilege). This caused the container to abort before any service started — only
`appinit` was visible in `ps aux`.

**Fix:** Write a minimal `custom_configs/start.sh` that just execs `supervisord`:

```bash
#!/bin/bash
exec supervisord -n -c /etc/supervisord.conf
```

Then bind-mount it over `/docker-entrypoint.sh`:

```
--bind $(pwd)/custom_configs/start.sh:/docker-entrypoint.sh
```

**Why this way:** The runscript calls whatever is at `/docker-entrypoint.sh`, so replacing it
via bind mount is the least invasive fix — no SIF rebuild required, and the override is
explicit and reversible.

---

### 3. Port 80 is a privileged port — unprivileged users cannot bind to it

**Problem:** The nginx vhost config inside the SIF listens on port 80. Binding to ports below
1024 requires root on Linux. Apptainer runs as an unprivileged user, so nginx would fail.

**Fix:** Extract the vhost config, patch it with `sed`, and bind-mount the patched version:

```bash
apptainer exec shopping_admin.sif cat /etc/nginx/conf.d/default.conf > custom_configs/conf_default.conf
sed -i 's/listen 80/listen 7780/g' custom_configs/conf_default.conf
```

**Why this way:** Patching on the host and bind-mounting avoids modifying the SIF.
Port 7780 is the WebArena-standard port for this service and is unprivileged.

---

### 4. Elasticsearch uses `su elastico` — fails without root

**Problem:** The original supervisor config starts Elasticsearch via `su elastico -c ...`,
which requires root to switch users. This would silently fail under Apptainer.

**Fix:** The custom `supervisord.conf` calls the Elasticsearch binary directly:

```ini
[program:elasticsearch]
command=/usr/share/java/elasticsearch/bin/elasticsearch
```

**Why this way:** Running as the current (unprivileged) user is correct for rootless containers.
Elasticsearch does not actually require a specific user; the `su` was a Docker-ism.

---

### 5. `mysqld --user=mysql` flag causes failure without root

**Problem:** The original supervisor config passed `--user=mysql` to `mysqld`, instructing it
to drop privileges to the `mysql` OS user. This fails when already running as an unprivileged
user (can't drop to a different user without root).

**Fix:** The custom `supervisord.conf` omits the `--user=mysql` flag from the `mysqld` command.

**Why this way:** When running as a non-root user, MySQL doesn't need to drop privileges —
it's already unprivileged. Removing the flag is the correct fix.

---

### 6. Magento base URL hardcoded to CMU's server

**Problem:** The Magento database stores the site's base URL. In the original image it points
to `http://metis.lti.cs.cmu.edu:7780/`. After boot, all HTTP responses redirect to that address,
making the site unreachable from the HPC node.

**Fix:** After first boot, patch the URL directly in the database and flush Magento's cache:

```bash
mysql -u root --socket=/run/mysqld/mysqld.sock magento -e "
    UPDATE core_config_data SET value='http://localhost:7780/'
    WHERE path='web/unsecure/base_url';
    UPDATE core_config_data SET value='http://localhost:7780/'
    WHERE path='web/secure/base_url';
"
php /var/www/magento2/bin/magento cache:flush
php /var/www/magento2/bin/magento indexer:reindex
```

**Why this way:** Magento caches configuration aggressively. The DB update sets the correct
value; the cache flush ensures Magento reads the new value; the reindex rebuilds the search
index which may have stale URL references.

---

### 7. nginx fails to start — missing `tmp/` subdirectories under `/var/lib/nginx`

**Problem:** nginx requires several subdirectories under its working directory for temporary
files (`client_body`, `proxy`, `fastcgi`, `uwsgi`, `scgi`). When `/var/lib/nginx` is
bind-mounted from `webarena_data/nginx/` (which was initially extracted with only a `logs/`
subdir), nginx would crash at startup with:

```
mkdir() "/var/lib/nginx/tmp/client_body" failed (2: No such file or directory)
```

**Fix:** Explicitly create these directories during setup and at the start of every run:

```bash
mkdir -p webarena_data/nginx/tmp/client_body
mkdir -p webarena_data/nginx/tmp/proxy
mkdir -p webarena_data/nginx/tmp/fastcgi
mkdir -p webarena_data/nginx/tmp/uwsgi
mkdir -p webarena_data/nginx/tmp/scgi
```

**Why this way:** nginx tries to `mkdir` these itself but cannot because the parent `/var/lib/nginx`
is a bind mount owned by the host user. Pre-creating them on the host side before the bind
mount is established ensures they exist when nginx starts.

---

### 8. `apptainer instance start` does not launch supervisord — `%startscript` is empty

**Problem:** When the Docker image was converted to a SIF, the `%startscript` section was left
empty (only boilerplate copyright comments). `apptainer instance start` runs `%startscript`, not
`%runscript`, so the instance starts (the `appinit` namespace process appears in `ps`) but
**supervisord is never launched** and all services remain dead. The site returns connection
timeouts even though `apptainer instance list` shows the instance as running.

This can be verified with:
```bash
apptainer inspect --startscript shopping_admin.sif   # empty / only copyright header
apptainer inspect --runscript shopping_admin.sif      # has OCI_ENTRYPOINT and OCI_CMD
```

**Fix:** After `apptainer instance start` creates the namespace, explicitly launch supervisord
via `apptainer exec`:

```bash
apptainer instance start [bind mounts...] shopping_admin.sif webarena_shopping_admin
apptainer exec instance://webarena_shopping_admin \
  supervisord -n -c /etc/supervisord.conf &
```

**Why this way:** `apptainer exec` runs a command inside an already-running instance using its
bind mounts and namespace — the correct hook for this pattern. Running supervisord in the
background (`&`) lets the script continue to poll for readiness.

---

## Directory Layout

```
shopping_admin/
├── set_up.sh                  # One-time setup script
├── run_shopping_admin.sh      # Start script for subsequent runs
├── download.sh                # Downloads the Docker tar archive
├── shopping_admin.sif         # Built Apptainer image (generated by set_up.sh)
├── shopping_admin_final_0719.tar  # Source Docker image
├── custom_configs/            # Bind-mounted config overrides
│   ├── start.sh               # Replaces docker-entrypoint.sh
│   ├── supervisord.conf       # Rootless-patched supervisor config
│   ├── nginx.conf             # nginx main config
│   └── conf_default.conf      # nginx vhost (port-patched to 7780)
└── webarena_data/             # Extracted writable data (bind-mounted into container)
    ├── mysql/                 # MySQL data directory
    ├── redis/                 # Redis data
    ├── esdata/                # Elasticsearch data
    ├── eslog/                 # Elasticsearch logs
    ├── es_config/             # Elasticsearch config (with single-node patch)
    ├── magento_var/           # Magento var/ directory
    ├── magento_generated/     # Magento generated code
    ├── nginx/                 # nginx working dirs (logs/, tmp/)
    ├── log/                   # System logs (/var/log)
    ├── run/                   # Runtime sockets/pids (/run)
    └── tmp/                   # Temp files (/tmp)
```
