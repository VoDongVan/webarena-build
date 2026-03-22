# WebArena Shopping Site Setup on Unity HPC (Apptainer)

This guide is generated with Claude.
This guide walks through setting up the WebArena shopping site on UMass Unity HPC
using Apptainer (Docker is not permitted on Unity).

---
## TODO:
The guide is based on what I have done, so I am confident that it will roughly correct, but I need to verify it again.

---

## Prerequisites

- Access to Unity HPC (`unity.rc.umass.edu`)
- A large enough directory, e.g. `/scratch3/workspace/<your_directory>/webarena_build/shopping/`
- Apptainer available on the cluster (it is pre-installed on Unity)

---

## Directory Structure

All files live under a single build directory. This guide uses:

```
/scratch3/workspace/<your_directory>/webarena_build/shopping/
```

Replace this path with your own scratch directory throughout.

--
## Step 0 - TLDR: Fast set up
If you don't want to read all of the stuff below, do this:
### Todo: 
I never run set_up.sh. Verify that it works.

### On the compute node
You only need to run set_up.sh once:
```bash
cd /scratch3/workspace/<your_directory>/webarena_build/
chmod +x setup.sh
sh setup.sh
salloc -c 4 -p cpu --mem=32G -t 24:00:00 #it took long to set up for large site, so choose your time accordingly
```
For every subsequent run, setup.sh is never needed again:
```bash
salloc -c 4 -p cpu --mem=32G -t 04:00:00
cd /scratch3/workspace/<your_directory>/webarena_build/
sh run_shopping.sh
```

---

## Step 1 — Request a Compute Node

Docker/Apptainer builds are too heavy for login nodes. Request an interactive session
on a CPU compute node with enough memory:

```bash
salloc -c 4 -p cpu --mem=32G -t 04:00:00
```

Once granted, you will be dropped into a shell on a compute node (e.g. `cpu010`).
Navigate to your build directory:

```bash
cd /scratch3/workspace/<your_directory>/webarena_build/shopping/
```

---

## Step 2 — Download the Image and Build the SIF

Download the WebArena shopping Docker image tarball from CMU:

```bash
wget http://metis.lti.cs.cmu.edu/webarena-images/shopping_final_0712.tar
```

Convert it to an Apptainer SIF. This only needs to be done once and may take
10–20 minutes:

```bash
apptainer build shopping.sif docker-archive:shopping_final_0712.tar
```

Verify it was created:

```bash
ls -lh shopping.sif
```

You can optionally delete the tar to save disk space once the SIF is built:

```bash
rm shopping_final_0712.tar
```

---

## Step 3 — Create the Directory Structure

Create all host-side directories that will be bind-mounted into the container to
work around the read-only SIF filesystem:

```bash
mkdir -p custom_configs
mkdir -p webarena_data/nginx/logs
mkdir -p webarena_data/mysql
mkdir -p webarena_data/tmp
mkdir -p webarena_data/log
mkdir -p webarena_data/run
mkdir -p webarena_data/esdata
mkdir -p webarena_data/eslog
mkdir -p webarena_data/magento_var
mkdir -p webarena_data/magento_generated
```

---

## Step 4 — Extract Data from the SIF (One-Time Setup)

Several directories inside the SIF contain pre-populated data that must be writable
at runtime. Extract them to host directories once:

### MySQL data (pre-populated Magento database)
```bash
apptainer exec shopping.sif cp -a /var/lib/mysql/. webarena_data/mysql/
chmod -R 777 webarena_data/mysql
```

### Elasticsearch data
```bash
apptainer exec shopping.sif cp -a /usr/share/java/elasticsearch/data/. webarena_data/esdata/
chmod -R 777 webarena_data/esdata
```

### Elasticsearch logs
```bash
apptainer exec shopping.sif cp -a /usr/share/java/elasticsearch/logs/. webarena_data/eslog/
chmod -R 777 webarena_data/eslog
```

### Magento var directory (cache, sessions, logs)
```bash
apptainer exec shopping.sif cp -a /var/www/magento2/var/. webarena_data/magento_var/
chmod -R 777 webarena_data/magento_var
```

### Magento generated code
```bash
apptainer exec shopping.sif cp -a /var/www/magento2/generated/. webarena_data/magento_generated/
chmod -R 777 webarena_data/magento_generated
```

---

## Step 5 — Create Custom Config Files

### nginx port config

nginx inside the container binds to port 80 by default, which requires root.
Extract the config files and patch them to use port 8080:

```bash
apptainer exec shopping.sif cat /etc/nginx/conf.d/default.conf > custom_configs/conf_default.conf
apptainer exec shopping.sif cat /etc/nginx/http.d/default.conf > custom_configs/http_default.conf

sed -i 's/listen 80/listen 8080/g' custom_configs/conf_default.conf
sed -i 's/listen \[::\]:80/listen \[::\]:8080/g' custom_configs/conf_default.conf
sed -i 's/listen 80/listen 8080/g' custom_configs/http_default.conf
sed -i 's/listen \[::\]:80/listen \[::\]:8080/g' custom_configs/http_default.conf
```

### Elasticsearch supervisor config

The default supervisor config runs Elasticsearch via `su elastico`, which requires
root and always fails under Apptainer. Replace it with a rootless version:

```bash
cat > custom_configs/elasticsearch.ini << 'EOF'
[program:elasticsearch]
command=bash -c "ES_JAVA_HOME=/usr elasticsearch"
autostart=true
autorestart=true
priority=8
startretries=3
stopwaitsecs=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF
```

---

## Step 6 — Create run_shopping.sh

Create the main startup script:

```bash
cat > run_shopping.sh << 'EOF'
#!/bin/bash

cd /scratch3/workspace/<your_directory>/webarena_build/shopping/
chmod -R 777 /scratch3/workspace/<your_directory>/webarena_build/shopping/webarena_data

# Re-extract nginx configs each run (port 80 → 8080)
apptainer exec shopping.sif cat /etc/nginx/conf.d/default.conf > $(pwd)/custom_configs/conf_default.conf
apptainer exec shopping.sif cat /etc/nginx/http.d/default.conf > $(pwd)/custom_configs/http_default.conf

sed -i 's/listen 80/listen 8080/g' $(pwd)/custom_configs/conf_default.conf
sed -i 's/listen \[::\]:80/listen \[::\]:8080/g' $(pwd)/custom_configs/conf_default.conf
sed -i 's/listen 80/listen 8080/g' $(pwd)/custom_configs/http_default.conf
sed -i 's/listen \[::\]:80/listen \[::\]:8080/g' $(pwd)/custom_configs/http_default.conf

# Copy MySQL data if not already done
if [ ! -d "$(pwd)/webarena_data/mysql/mysql" ]; then
    echo "Initializing MySQL data from SIF..."
    apptainer exec shopping.sif cp -a /var/lib/mysql/. $(pwd)/webarena_data/mysql/
    chmod -R 777 $(pwd)/webarena_data/mysql
fi

# Start the instance with all bind mounts
apptainer instance run \
  --bind $(pwd)/custom_configs/conf_default.conf:/etc/nginx/conf.d/default.conf \
  --bind $(pwd)/custom_configs/http_default.conf:/etc/nginx/http.d/default.conf \
  --bind $(pwd)/custom_configs/elasticsearch.ini:/etc/supervisor.d/elasticsearch.ini \
  --bind $(pwd)/webarena_data/nginx:/var/lib/nginx \
  --bind $(pwd)/webarena_data/mysql:/var/lib/mysql \
  --bind $(pwd)/webarena_data/tmp:/tmp \
  --bind $(pwd)/webarena_data/log:/var/log \
  --bind $(pwd)/webarena_data/run:/var/run \
  --bind $(pwd)/webarena_data/esdata:/usr/share/java/elasticsearch/data \
  --bind $(pwd)/webarena_data/eslog:/usr/share/java/elasticsearch/logs \
  --bind $(pwd)/webarena_data/magento_var:/var/www/magento2/var \
  --bind $(pwd)/webarena_data/magento_generated:/var/www/magento2/generated \
  --env "ES_JAVA_OPTS=-Xms512m -Xmx512m" \
  shopping.sif webarena_shopping
EOF
```

Replace `<your_directory>` with your actual directory, then make it executable:

```bash
chmod +x run_shopping.sh
```

---

## Step 7 — First Boot and Post-Start Configuration

This only needs to be done once after the very first `run_shopping.sh`.

### Start the instance

```bash
sh run_shopping.sh
sleep 15
```

### Verify all services are running

```bash
apptainer exec instance://webarena_shopping ps aux | grep -E 'mysql|redis|php|nginx|elastic'
```

You should see `mysqld`, `php-fpm`, `nginx`, `redis-server`, and `elasticsearch` all listed.

### Fix the Magento base URL

The database has the original CMU server URL baked in. Update it to point to localhost:

```bash
apptainer exec instance://webarena_shopping mysql -u magentouser -pMyPassword -h 127.0.0.1 magentodb -e \
  "UPDATE core_config_data SET value='http://localhost:7770/' WHERE path LIKE 'web/%base_url%';"
```

### Flush cache and reindex

```bash
apptainer exec instance://webarena_shopping php /var/www/magento2/bin/magento cache:flush
apptainer exec instance://webarena_shopping php /var/www/magento2/bin/magento indexer:reindex 2>&1
```

The reindex takes a few minutes. When it finishes, all indexers should report success.

### Verify the site is up

```bash
apptainer exec instance://webarena_shopping curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080
```

Should return `200`.

---

## Step 8 — Access from Your Laptop via SSH Tunnel

On your **local machine**, open a terminal and run:

```bash
ssh -i ~/.ssh/unity-privkey.key -L 7770:<compute_node>:8080 <your_directory>@unity.rc.umass.edu
```

Replace `<compute_node>` with the node you are on (e.g. `cpu010`), which you can
find by running `hostname` on the cluster.

Then open your browser and navigate to:

```
http://localhost:7770
```

---

## Step 9 — Subsequent Runs

After the first boot setup, subsequent runs are just:

```bash
salloc -c 4 -p cpu --mem=32G -t 04:00:00
cd /scratch3/workspace/<your_directory>/webarena_build/shopping/
sh run_shopping.sh
```

No reindexing or URL patching needed — all state is persisted in `webarena_data/`.

---

## Stopping the Instance

```bash
apptainer instance stop webarena_shopping
```

---

## Troubleshooting

### 500 Internal Server Error
Check the Magento exception log:
```bash
apptainer exec instance://webarena_shopping cat /var/www/magento2/var/log/exception.log | tail -50
```

Check supervisord to see which services failed to start:
```bash
cat webarena_data/log/supervisord.log | tail -30
```

### Category pages show no products
Elasticsearch may not be running yet. Wait 15–20 seconds after startup and reindex:
```bash
apptainer exec instance://webarena_shopping php /var/www/magento2/bin/magento indexer:reindex catalogsearch_fulltext 2>&1
```

### 302 redirect to metis.lti.cs.cmu.edu
The base URL in the database was not updated. Re-run the URL fix from Step 7.

### Links go to localhost:8080 instead of localhost:7770
Either use `-L 8080:<node>:8080` in your SSH tunnel, or update the base URL in the
database to `http://localhost:7770/` as shown in Step 7.

### MySQL access denied for root
Use the Magento credentials instead: `-u magentouser -pMyPassword -h 127.0.0.1`

---

## Summary of Key Constraints

| Problem | Root Cause | Solution |
|---|---|---|
| Can't use Docker | Unity security policy | Use Apptainer to run Docker images |
| Can't bind to port 80 | No root in Apptainer | Patch nginx config to use port 8080 |
| MySQL read-only | SIF filesystem is immutable | Extract `/var/lib/mysql` and bind-mount |
| Elasticsearch crashes | `su elastico` requires root | Custom supervisor ini without `su` |
| ES gc.log read-only | SIF filesystem is immutable | Extract ES logs dir and bind-mount |
| Magento 500 error | `var/` not writable | Extract `/var/www/magento2/var` and bind-mount |
| Category pages empty | Stale compiled code pointing to ES | Extract `generated/` and bind-mount, then reindex |
| Wrong base URL | Database has CMU URL | UPDATE `core_config_data` to localhost |