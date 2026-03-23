# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

This directory sets up the **Magento 2 admin panel** (WebArena `shopping_admin` environment) to run under **Apptainer** on UMass Unity HPC. Docker is forbidden on Unity; the CMU-provided Docker image (`shopping_admin_final_0719.tar`) is converted to a SIF and run rootlessly.

- **Port:** 7780
- **Apptainer instance name:** `webarena_shopping_admin`
- **Admin URL:** `http://localhost:7780/admin`

## Key Commands

**First-time setup** (run once from a compute node after `salloc`):
```bash
bash set_up.sh
```

**Start the site** (every subsequent run):
```bash
bash run_shopping_admin.sh
```

**Stop the instance:**
```bash
apptainer instance stop webarena_shopping_admin
```

**SSH tunnel to access from laptop:**
```bash
ssh -L 7780:<node-hostname>:7780 <username>@unity.rc.umass.edu
```
Get `<node-hostname>` by running `hostname` on the compute node.

**Run a command inside the running instance:**
```bash
apptainer exec instance://webarena_shopping_admin <command>
```

**Check instance status:**
```bash
apptainer instance list
```

**Inspect the SIF's startscript vs runscript** (useful for debugging startup issues):
```bash
apptainer inspect --startscript shopping_admin.sif
apptainer inspect --runscript shopping_admin.sif
```

## Architecture

The container is a **read-only SIF** (Apptainer image) with all mutable state bind-mounted from the host. The SIF's `%startscript` is empty (Docker conversion artifact), so supervisord must be launched explicitly via `apptainer exec` after `apptainer instance start`.

### Bind-Mount Pattern

All writable service data lives in `webarena_data/` on the host and is mounted into the container at the paths services expect:

| Host path | Container path | Service |
|---|---|---|
| `webarena_data/mysql/` | `/var/lib/mysql` | MariaDB |
| `webarena_data/redis/` | `/var/lib/redis` | Redis |
| `webarena_data/esdata/` | `/usr/share/java/elasticsearch/data` | Elasticsearch |
| `webarena_data/eslog/` | `/usr/share/java/elasticsearch/logs` | Elasticsearch |
| `webarena_data/es_config/` | `/usr/share/java/elasticsearch/config` | Elasticsearch |
| `webarena_data/magento_var/` | `/var/www/magento2/var` | Magento |
| `webarena_data/magento_generated/` | `/var/www/magento2/generated` | Magento |
| `webarena_data/nginx/` | `/var/lib/nginx` | nginx |
| `webarena_data/log/` | `/var/log` | all services |
| `webarena_data/run/` | `/run` | sockets/pids |
| `webarena_data/tmp/` | `/tmp` | temp files |

### Config Override Pattern

`custom_configs/` contains host-side config files that are bind-mounted **over** the SIF's read-only configs:

| File | Overrides | Purpose |
|---|---|---|
| `start.sh` | `/docker-entrypoint.sh` | Bypasses `chown mysql:mysql` which requires root |
| `supervisord.conf` | `/etc/supervisord.conf` | Removes `--user=mysql` and `su elastico` (rootless fixes) |
| `nginx.conf` | `/etc/nginx/nginx.conf` | nginx main config |
| `conf_default.conf` | `/etc/nginx/conf.d/default.conf` | nginx vhost patched from port 80 → 7780 |

`conf_default.conf` and `start.sh` are regenerated on every `run_shopping_admin.sh` run to ensure they're current.

### Service Stack (via supervisord)

Priority order: `mysqld` (1) → `redis-server` (2) → `php-fpm` (3) → `elasticsearch` (4) → `nginx` (5) → `cron` (6)

## Rootless Apptainer Constraints

All fixes in this repo exist because Unity HPC runs Apptainer without root. Key constraints:
- Cannot bind ports < 1024 → nginx listens on 7780, not 80
- Cannot `chown` to other users → `docker-entrypoint.sh` is replaced
- Cannot `su` to switch users → `su elastico` and `--user=mysql` are removed
- SIF filesystem is immutable → all config changes use bind mounts, no SIF rebuild needed
- `%startscript` is empty in converted SIFs → supervisord launched via `apptainer exec` after instance start

## Running Both Servers Simultaneously

Shopping and shopping_admin cannot share a node (port conflicts on 3306 and 9200). Use the SLURM scripts instead of the direct run scripts:

```bash
sbatch slurm_shopping_admin.sh        # from shopping_admin/
sbatch ../shopping/slurm_shopping.sh  # from shopping/
```

Both servers are then reachable by hostname from anywhere on the cluster:
```bash
curl -s -o /dev/null -w "%{http_code}" http://<node>:7780
```

Stop by cancelling the SLURM job (`scancel <jobid>`), which kills the node allocation and instance together. See `../README.md` for the full two-server workflow.

## First-Boot URL Patch

After setup, Magento's DB has the base URL pointing to CMU's server. The setup script patches it:
```bash
apptainer exec instance://webarena_shopping_admin \
    mysql -u root --socket=/run/mysqld/mysqld.sock magento -e "
        UPDATE core_config_data SET value='http://localhost:7780/'
        WHERE path IN ('web/unsecure/base_url', 'web/secure/base_url');
    "
apptainer exec instance://webarena_shopping_admin php /var/www/magento2/bin/magento cache:flush
apptainer exec instance://webarena_shopping_admin php /var/www/magento2/bin/magento indexer:reindex
```
This is a one-time operation; subsequent runs use the already-patched data in `webarena_data/mysql/`.
