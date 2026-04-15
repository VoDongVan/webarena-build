# Running WebArena on Unity HPC: Apptainer Challenges and Solutions

WebArena was designed to run with Docker. Unity HPC forbids Docker, so all six services
run as **Apptainer** (formerly Singularity) instances on dedicated SLURM CPU nodes. This
document records the problems we hit adapting Docker-based images to Apptainer, and the
solutions implemented in the `run_*.sh` scripts.

---

## Background: How the Servers Are Organized

Six services are required:

| Service | What It Is | Port | SLURM Resources |
|---|---|---|---|
| Shopping | Magento e-commerce (PHP + MySQL + nginx + Elasticsearch) | 7770 | 2 CPUs, 16 GB |
| Shopping Admin | Same Magento stack, admin panel | 7780 | 2 CPUs, 16 GB |
| Reddit | Postmill forum (PHP + nginx + PostgreSQL) | 9999 | 2 CPUs, 8 GB |
| GitLab | GitLab CE Omnibus | 8023 | 2 CPUs, 16 GB |
| Wikipedia | Kiwix serving a static ZIM file | 8888 | 2 CPUs, 8 GB |
| Homepage | Flask app linking to all services | 4399 | 1 CPU, 4 GB |

Each service gets one SLURM job. After the service becomes healthy, `run_<svc>.sh` writes
the compute node hostname to `homepage/.<svc>_node`. The homepage Flask app, `connect.sh`,
and test scripts all read these files to locate services — no hard-coded hostnames anywhere.

`launch_all.sh` submits Shopping first, waits for its node assignment, then submits
Shopping Admin with `--exclude=<shopping_node>` to guarantee they land on **different
nodes** (they conflict on MySQL port 3306 and Elasticsearch port 9200).

---

## Core Pattern: Fresh-State Extraction to /tmp

All services (except Wikipedia) use the same pattern:

1. **Wipe** `/tmp/webarena_runtime_<svc>/` at job start
2. **Extract** all database and state data from the read-only SIF image into `/tmp/webarena_runtime_<svc>/` using `apptainer exec $SIF cp -a /path/. $WORKSPACE/dir/`
3. **Bind-mount** the extracted dirs into the container at the paths services expect
4. **Start** the Apptainer instance and launch services
5. **Wait** for full readiness before writing the `.node` file
6. **Cleanup** on exit: stop instance, wipe `/tmp` workspace

Wikipedia skips steps 1–3 because kiwix-serve only reads the ZIM file; it has no writable
state and runs directly via `apptainer exec ... &`.

**Why /tmp and not NFS?** scratch3 (NFS) does not implement POSIX `fcntl()` byte-range
locks. InnoDB (MySQL), Elasticsearch's `NativeFSLockFactory`, PHP-FPM's accept mutex, and
PostgreSQL's WAL all use these locks — they return `EIO` on NFS and crash immediately.
The compute node's `/tmp` is local SSD and supports locking correctly. Fresh extraction
also guarantees a clean known state on every start, which is what WebArena benchmarks require.

---

## Challenge 1: SIF %startscript Is Empty

**Problem**: Converting a Docker image to a SIF leaves the `%startscript` section empty.
`apptainer instance start` runs `%startscript`, which does nothing. Services never launch.

**Solution**: After `apptainer instance start`, explicitly execute the entrypoint:

```bash
apptainer instance start ... $SIF_FILE $INSTANCE_NAME
apptainer exec instance://$INSTANCE_NAME /docker-entrypoint.sh &
```

For GitLab (which uses runit, not supervisord), `runsvdir` is launched directly:

```bash
apptainer exec instance://webarena_gitlab \
  /opt/gitlab/embedded/bin/runsvdir -P /opt/gitlab/service &
```

Applied in: `run_reddit.sh`, `run_gitlab.sh`.

---

## Challenge 2: Docker Entrypoints Require Root

**Problem**: WebArena Docker images use `docker-entrypoint.sh` scripts that run
`chown -R mysql:mysql /var/lib/mysql` and similar ownership-changing commands.
Rootless Apptainer has no root — these fail and services never start.

**Solution**: Bind-mount a minimal replacement entrypoint that skips the `chown` step
and jumps directly to supervisord:

```bash
cat > custom_configs/start.sh << 'EOF'
#!/bin/sh
exec supervisord -n -c /etc/supervisord.conf
EOF
chmod +x custom_configs/start.sh

apptainer instance start \
  --bind custom_configs/start.sh:/docker-entrypoint.sh \
  ...
```

Applied in: `run_shopping_admin.sh` (replaces `chown mysql:mysql`), `run_reddit.sh`
(replaces `chown nginx:nginx` and `su postgres`).

---

## Challenge 3: Hard-coded Port 80

**Problem**: nginx in all SIF images listens on port 80. Rootless Apptainer cannot bind
ports below 1024.

**Solution**: Extract the nginx vhost config from the SIF at runtime, patch the port
number with `sed`, then bind-mount the patched config back over the original:

```bash
apptainer exec $SIF_FILE cat /etc/nginx/conf.d/default.conf > custom_configs/conf_default.conf
sed -i "s/listen 80/listen $PORT/g" custom_configs/conf_default.conf

apptainer instance start \
  --bind custom_configs/conf_default.conf:/etc/nginx/conf.d/default.conf \
  ...
```

The extraction and patching happen on every launch so they always reflect the current port.

Applied in: `run_shopping.sh`, `run_shopping_admin.sh`, `run_reddit.sh`, `run_gitlab.sh`.

---

## Challenge 4: Magento and GitLab Hard-code Their Hostname

**Problem**: Magento stores the site's base URL in MySQL (`core_config_data` table).
GitLab stores it in `gitlab.rb`. Both point to CMU's server hostname. When the SLURM job
lands on a different node, all links and redirects break.

**Solution for Magento**: After MySQL is ready, run a live SQL UPDATE with the current
node hostname, then flush Magento's cache:

```bash
NODE=$(hostname)
apptainer exec instance://webarena_shopping \
  mysql -h127.0.0.1 -umagentouser -pMyPassword magentodb -e \
  "UPDATE core_config_data SET value='http://$NODE:7770/'
   WHERE path LIKE 'web/%base_url%';"
apptainer exec instance://webarena_shopping \
  php /var/www/magento2/bin/magento cache:flush
```

**Solution for GitLab**: Patch `gitlab.rb` before starting the instance (fresh extraction
means no `gitlab-ctl reconfigure` needed):

```bash
sed -i "s|external_url .*|external_url 'http://$NODE:8023'|g" \
  "$WORKSPACE/etc_gitlab/gitlab.rb"
```

Applied in: `run_shopping.sh`, `run_shopping_admin.sh` (Magento); `run_gitlab.sh` (GitLab).

---

## Challenge 5: Supervisor Configs Use Root-Only Commands

**Problem**: The default supervisor (supervisord/runit) configs assume root:
- `mysqld --user=mysql` — `setuid()` to `mysql` OS user requires root
- `su elastico -c elasticsearch` — user switching requires root
- GitLab runit scripts: `chpst -u git:git` — `setgroups()` syscall blocked on HPC

**Solution**: Bind-mount patched supervisor configs that remove user-switching:

```ini
# Before (broken):
command=mysqld --user=mysql --log-error=/var/log/mysql/error.log
# After (fixed):
command=mysqld --log-error=/var/log/mysql/error.log
```

For GitLab, all affected runit `run` scripts are extracted, the `-u`/`-U` chpst flags
stripped, and bind-mounted from `custom_configs/sv_run/`.

Applied in: `shopping/custom_configs/mysql.ini`, `shopping_admin/custom_configs/supervisord.conf`,
`gitlab/custom_configs/sv_run/` (12 services patched).

---

## Challenge 6: GitLab PostgreSQL Peer Authentication

**Problem**: GitLab's `pg_hba.conf` uses peer authentication. The original `pg_ident.conf`
maps OS user `git` → DB user `gitlab`. On HPC, services run as the HPC user (e.g.
`vdvo_umass_edu`), so peer auth fails with "Peer authentication failed for user gitlab".

**Solution**: After extraction, append the current HPC user's mapping before starting:

```bash
echo "gitlab  $USER  gitlab" >> "$WORKSPACE/gitlab_data/postgresql/data/pg_ident.conf"
```

This runs automatically on every start, regardless of which HPC user submits the job.

Applied in: `run_gitlab.sh`.

---

## Challenge 7: GitLab's runit Requires HPC Workarounds

**Problem**: `runsvdir-start` (runit's startup wrapper) calls `ulimit -n` and writes to
`/proc/sys/fs/file-max`. Both are blocked on HPC nodes with "Operation not permitted".

**Solution**: Call `runsvdir` directly, bypassing `runsvdir-start`:

```bash
apptainer exec instance://webarena_gitlab \
  /opt/gitlab/embedded/bin/runsvdir -P /opt/gitlab/service &
```

Additionally, runit's `runsv` needs to write `supervise/lock` and `supervise/status` inside
each service directory. These are inside the immutable SIF. `--writable-tmpfs` overlays an
in-memory tmpfs on top of the SIF, allowing runit to write anywhere:

```bash
apptainer instance start --writable-tmpfs ...
```

Applied in: `run_gitlab.sh`.

---

## Challenge 8: Magento DI Code Generation on First /admin Request

**Problem**: If `magento_generated/` (PHP dependency injection code) is empty or missing,
the first request to `/admin` triggers on-demand compilation taking 3–8 minutes. Playwright
agents that navigate to `/admin` immediately will time out on the login form.

**Solution**: Extract the pre-compiled `magento_generated/` directory from the SIF (where
it was pre-compiled into the image), then pre-warm `/admin` before writing the readiness
file:

```bash
apptainer exec $SIF_FILE cp -a /var/www/magento2/generated/. "$WORKSPACE/magento_generated/"

# Warmup loop — runs up to 10 min until /admin responds
for i in $(seq 1 120); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 "http://$NODE:$PORT/admin/")
    [[ "${code:0:1}" == "2" || "${code:0:1}" == "3" ]] && break
    sleep 5
done
```

`.shopping_admin_node` is written only after this loop completes.

Applied in: `run_shopping_admin.sh`.

---

## Challenge 9: Services Not Reachable from Outside the Cluster

**Problem**: SLURM compute nodes sit behind Unity's internal network. Services running
on them are not accessible from the internet or from your laptop.

**Solution**: Use SSH's SOCKS5 proxy mode to tunnel all browser traffic through the
Unity login node:

```bash
# Run on your local machine:
ssh -D 1080 -N -f <username>@unity.rc.umass.edu
```

Configure your browser to use `localhost:1080` as a SOCKS5 proxy with "Proxy DNS" enabled.
All browser requests are then routed through Unity's network and can reach compute node
services by their internal hostnames.

The `connect.sh` script automates this: it reads all `.<svc>_node` files via SSH,
starts the SOCKS5 proxy, and prints the homepage URL.

---

## Quick Reference: Startup Checklist

```bash
# 1. From the webarena_build/ directory:
bash launch_all.sh

# 2. Wait ~10–15 min, then run smoke tests:
bash run_all_tests.sh

# 3. Or health-check individual services:
bash health_check.sh

# 4. To browse manually from your laptop:
bash connect.sh <your-unity-username>

# 5. To stop all servers:
bash stop_all.sh
```
