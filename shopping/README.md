# WebArena Shopping Site — Setup Guide (Unity HPC)

This directory sets up the **Magento 2 storefront** environment used by WebArena, adapted to run
under **Apptainer** on UMass Unity HPC. Unity forbids Docker, so the CMU-provided Docker image
(`shopping_final_0712.tar`) must be converted to a SIF and run rootlessly.

- **Port:** 7770
- **Apptainer instance name:** `webarena_shopping`
- **URL:** `http://localhost:7770/`

---

## Prerequisites

- You must be on a **compute node** (not a login node): `salloc -p cpu ...`
- Apptainer must be available (pre-installed on Unity)
- `shopping_final_0712.tar` must be present in this directory

---

## First-Time Setup

Run **once** per cluster filesystem location:

```bash
bash set_up.sh
```

This does the following in order:

1. Downloads `shopping_final_0712.tar` from CMU if not already present, then builds `shopping.sif` (10–20 min)
2. Creates `webarena_data/` and `custom_configs/` directory structures
3. Extracts writable data out of the SIF (MySQL, Elasticsearch, Magento var/generated)
4. Generates patched config files (nginx port, rootless Elasticsearch supervisor override)
5. Generates `run_shopping.sh`
6. Boots the instance for the first time
7. Patches the Magento base URL from CMU's server to `localhost:7770`, flushes cache, reindexes

All extraction steps are **idempotent** — re-running `set_up.sh` skips steps already done.

---

## Starting the Site (After Setup)

From the same directory on any compute node:

```bash
bash run_shopping.sh
```

---

## Stopping the Site

```bash
apptainer instance stop webarena_shopping
```

---

## Accessing from Your Local Machine

The site listens on `localhost:7770` inside the cluster. Use an SSH tunnel:

```bash
ssh -i ~/.ssh/unity-privkey.key -L 7770:<node-hostname>:7770 <your-username>@unity.rc.umass.edu
```

Get the current node hostname with `hostname` while on the compute node. Then open:

- Storefront: `http://localhost:7770/`
- Admin panel: `http://localhost:7770/admin`

---

## Important: Port Conflicts with shopping_admin

Shopping and shopping_admin **cannot run on the same compute node simultaneously** — both
use MySQL on port 3306 and Elasticsearch on port 9200. Stop one before starting the other:

```bash
apptainer instance stop webarena_shopping_admin   # then start shopping
# or
apptainer instance stop webarena_shopping         # then start shopping_admin
```

---

## Issues Encountered and How They Were Fixed

### 1. SIF is read-only — MySQL, Elasticsearch, and Magento need writable storage

**Problem:** Apptainer SIF files are immutable. MySQL, Elasticsearch, and Magento's
`var/` and `generated/` directories all require write access at runtime.

**Fix:** Extract those directories out of the SIF once into `webarena_data/`, then bind-mount
them back into the container at their original paths on every run:

```
--bind $(pwd)/webarena_data/mysql:/var/lib/mysql
--bind $(pwd)/webarena_data/esdata:/usr/share/java/elasticsearch/data
...
```

**Why this way:** Bind mounts let the container see the paths at their expected locations while
the actual files live on the writable host filesystem.

---

### 2. Port 80 is a privileged port — unprivileged users cannot bind to it

**Problem:** The nginx vhost config inside the SIF listens on port 80. Binding to ports below
1024 requires root on Linux. Apptainer runs as an unprivileged user, so nginx would fail.

**Fix:** Extract the vhost configs, patch them with `sed`, and bind-mount the patched versions:

```bash
apptainer exec shopping.sif cat /etc/nginx/conf.d/default.conf > custom_configs/conf_default.conf
sed -i 's/listen 80/listen 7770/g' custom_configs/conf_default.conf
```

**Why this way:** Patching on the host and bind-mounting avoids modifying the SIF.
Port 7770 is the WebArena-standard port for this service and is unprivileged.

---

### 3. Elasticsearch supervisor config uses `su` and wrong binary path

**Problem:** The default supervisor ini runs Elasticsearch via `su elastico -c ...`, which
requires root. Additionally, `elasticsearch` is not on the container's `PATH` — the binary
lives at `/usr/share/java/elasticsearch/bin/elasticsearch`.

**Fix:** Override the supervisor ini via bind-mount with a rootless version using the full path:

```ini
[program:elasticsearch]
command=/usr/share/java/elasticsearch/bin/elasticsearch
environment=ES_JAVA_HOME=/usr,ES_JAVA_OPTS="-Xms512m -Xmx512m"
```

**Why this way:** The bind-mounted `custom_configs/elasticsearch.ini` replaces the one baked
into the SIF at `/etc/supervisor.d/elasticsearch.ini`. No SIF rebuild needed.

---

### 4. nginx fails to start — missing `tmp/` subdirectories under `/var/lib/nginx`

**Problem:** nginx requires several subdirectories under its working directory for temporary
files (`client_body`, `proxy`, `fastcgi`, `uwsgi`, `scgi`). When `/var/lib/nginx` is
bind-mounted from `webarena_data/nginx/`, these subdirs don't exist yet, causing nginx to
crash at startup.

**Fix:** Explicitly create these directories during setup and at the start of every run:

```bash
mkdir -p webarena_data/nginx/tmp/client_body
mkdir -p webarena_data/nginx/tmp/proxy
mkdir -p webarena_data/nginx/tmp/fastcgi
mkdir -p webarena_data/nginx/tmp/uwsgi
mkdir -p webarena_data/nginx/tmp/scgi
```

---

### 5. Magento base URL hardcoded to CMU's server

**Problem:** The Magento database stores the site's base URL. In the original image it points
to `http://metis.lti.cs.cmu.edu:7770/`. After boot, all HTTP responses redirect to that address.

**Fix:** After first boot, patch the URL directly in the database and flush Magento's cache:

```bash
apptainer exec instance://webarena_shopping \
  mysql -u magentouser -pMyPassword -h 127.0.0.1 magentodb -e \
  "UPDATE core_config_data SET value='http://localhost:7770/'
   WHERE path LIKE 'web/%base_url%';"
php /var/www/magento2/bin/magento cache:flush
php /var/www/magento2/bin/magento indexer:reindex
```

---

## Directory Layout

```
shopping/
├── set_up.sh                  # One-time setup script
├── run_shopping.sh            # Start script for subsequent runs
├── shopping.sif               # Built Apptainer image (generated by set_up.sh)
├── shopping_final_0712.tar    # Source Docker image (deleted after SIF is built)
├── custom_configs/            # Bind-mounted config overrides
│   ├── elasticsearch.ini      # Rootless ES supervisor override
│   ├── conf_default.conf      # nginx vhost (port-patched to 7770)
│   └── http_default.conf      # nginx fallback vhost (port-patched to 7770)
└── webarena_data/             # Extracted writable data (bind-mounted into container)
    ├── mysql/                 # MySQL data directory
    ├── esdata/                # Elasticsearch data
    ├── eslog/                 # Elasticsearch logs
    ├── magento_var/           # Magento var/ directory
    ├── magento_generated/     # Magento generated code
    ├── nginx/                 # nginx working dirs (logs/, tmp/)
    ├── log/                   # System logs (/var/log)
    ├── run/                   # Runtime sockets/pids (/var/run)
    └── tmp/                   # Temp files (/tmp)
```

---

## Troubleshooting

### 500 Internal Server Error

Check supervisord to see which services failed:
```bash
cat webarena_data/log/supervisord.log | tail -30
apptainer exec instance://webarena_shopping supervisorctl status
```

Check Magento exception log:
```bash
cat webarena_data/magento_var/log/exception.log | tail -50
```

### Category pages show no products

Elasticsearch may still be starting up (it takes ~30 seconds). Wait and reindex:
```bash
apptainer exec instance://webarena_shopping \
  php /var/www/magento2/bin/magento indexer:reindex catalogsearch_fulltext 2>&1
```

### 302 redirect to metis.lti.cs.cmu.edu

The base URL in the database was not updated. Re-run the URL fix from the first-time setup
(Step 7 of set_up.sh). This should only happen on a completely fresh first boot.

### Instance starts but services crash (port conflict)

Shopping and shopping_admin both use MySQL on port 3306. If both instances are running on
the same node, MySQL will fail with "Address in use". Stop the other instance first.
