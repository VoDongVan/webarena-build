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

Each service gets one SLURM job. The job:
1. Writes the assigned node hostname to `homepage/.<svc>_node`
2. Calls `run_<svc>.sh`
3. Ends with `sleep infinity` (or a foreground process for GitLab) to keep the allocation alive

The agent reads the `.<svc>_node` files at startup to build service URLs — no hard-coded
hostnames anywhere in the agent code.

`launch_all.sh` submits Shopping first, waits for its node assignment, then submits
Shopping Admin with `--exclude=<shopping_node>` to guarantee they land on **different
nodes** (they conflict on MySQL port 3306 and Elasticsearch port 9200).

---

## Challenge 1: Docker Entrypoints Require Root

**Problem**: WebArena's original Docker images use `docker-entrypoint.sh` scripts that
run `chown -R www-data:www-data /var/www/...` and similar ownership-changing commands.
On Apptainer you are never root inside the container, so these commands fail and the
services won't start.

**Solution**: Bind-mount a custom `start.sh` over `/docker-entrypoint.sh` that skips
the `chown` step and jumps directly to `supervisord`:

```bash
cat > custom_configs/start.sh << 'EOF'
#!/bin/bash
exec supervisord -n -c /etc/supervisord.conf
EOF
chmod +x custom_configs/start.sh

apptainer instance start \
  --bind custom_configs/start.sh:/docker-entrypoint.sh \
  ...
```

This is applied in `run_shopping_admin.sh` and `run_reddit.sh`.

---

## Challenge 2: Read-Only Container Filesystem

**Problem**: Apptainer mounts the SIF image read-only. Services like nginx, MySQL,
PostgreSQL, and Elasticsearch need writable directories for data, logs, sockets, and
temp files. Writes inside the container fail silently or crash the service.

**Solution**: Bind-mount a writable `webarena_data/` directory tree from the host into
every path the service writes to:

```bash
apptainer instance start \
  --bind webarena_data/nginx:/var/lib/nginx \
  --bind webarena_data/mysql:/var/lib/mysql \
  --bind webarena_data/tmp:/tmp \
  --bind webarena_data/log:/var/log \
  --bind webarena_data/run:/var/run \
  --bind webarena_data/esdata:/usr/share/java/elasticsearch/data \
  ...
```

All persistent state lives on the shared filesystem (`/scratch3/`), not inside the
container image. The bind-mount list was built by running the service, finding where it
crashed, and adding that path — repeated until the service started cleanly.

---

## Challenge 3: Hard-coded Port 80

**Problem**: The original nginx configs listen on port 80. On Unity (and most HPC
systems) non-root users cannot bind to ports below 1024, so nginx fails to start.

**Solution**: Extract the nginx config from the SIF at runtime, patch the port numbers
with `sed`, then bind-mount the patched config back over the original:

```bash
apptainer exec shopping.sif cat /etc/nginx/conf.d/default.conf > custom_configs/conf_default.conf
sed -i 's/listen 80/listen 7770/g' custom_configs/conf_default.conf
sed -i 's/listen \[::\]:80/listen \[::\]:7770/g' custom_configs/conf_default.conf

apptainer instance start \
  --bind custom_configs/conf_default.conf:/etc/nginx/conf.d/default.conf \
  ...
```

The extraction and patching happen on every launch (not baked into the SIF) because the
config may need re-patching after a node change.

---

## Challenge 4: Magento Hard-codes Its Hostname in MySQL

**Problem**: Magento stores the site's base URL in a MySQL table (`core_config_data`).
If the SLURM job lands on a different node than the previous run, all HTTP redirects,
asset URLs, and form actions point to the old hostname — the storefront appears broken
even though the service itself is running.

**Solution**: After MySQL is ready, run a live SQL `UPDATE` using the current node's
hostname, then flush Magento's application cache:

```bash
NODE=$(hostname)
apptainer exec instance://webarena_shopping \
  mysql -h127.0.0.1 -umagentouser -pMyPassword magentodb -e \
  "UPDATE core_config_data
   SET value='http://$NODE:7770/'
   WHERE path LIKE 'web/%base_url%';"

apptainer exec instance://webarena_shopping \
  php /var/www/magento2/bin/magento cache:flush
```

Both `run_shopping.sh` and `run_shopping_admin.sh` do this on every startup.

---

## Challenge 5: Stale Lock Files After Abnormal Shutdown

**Problem**: PostgreSQL (used by Reddit and GitLab) writes a `postmaster.pid` file when
it starts. If the SLURM job is killed (timeout, preemption, `scancel`), the pid file is
left behind on the bind-mounted data directory. The next startup sees the file, assumes
PostgreSQL is already running, and refuses to start — causing the service to silently
fail.

**Solution**: Explicitly delete known stale lock files before starting the instance:

```bash
rm -f "$WORKDIR/webarena_data/pgsql/postmaster.pid"
rm -f "$WORKDIR/webarena_data/run/postgresql/.s.PGSQL.5432.lock"
```

Both `run_reddit.sh` and `run_gitlab.sh` do this at the top of the script, before
`apptainer instance start`.

---

## Challenge 6: PostgreSQL's Strict Directory Permission Check

**Problem**: PostgreSQL refuses to start if its data directory has group-write or
world-write permissions — this is a deliberate security check, not a bug. But the rest
of the data directories need permissive permissions (e.g. `777`) so the unprivileged
container user can write to them.

**Solution**: Apply permissions selectively rather than globally:

```bash
# PostgreSQL data dir: must be 700 (owner-only)
chmod -R 700 "$WORKDIR/webarena_data/pgsql"

# Runtime dirs: permissive so the container user can write
chmod -R 777 "$WORKDIR/webarena_data/run"
chmod -R 777 "$WORKDIR/webarena_data/log"
chmod -R 777 "$WORKDIR/webarena_data/tmp"
```

---

## Challenge 7: GitLab's Complex Multi-Service Orchestration

**Problem**: GitLab Omnibus manages ~12 sub-services (PostgreSQL, Redis, Puma, Sidekiq,
Gitaly, nginx, Prometheus, etc.) using `runit` (runsvdir). The Docker image had an
`ENTRYPOINT` that handled this, but Apptainer SIF images have a `%startscript` section
— and for converted Docker images this is often empty. Simply starting the Apptainer
instance does nothing; no services come up.

Additionally, GitLab's `runit` service scripts are inside the read-only SIF and assume
root-level access for several operations.

**Solution**: Bind-mount custom `run` scripts for each GitLab sub-service, then launch
`runsvdir` directly from the SLURM script (in the foreground, so the job stays alive
without needing `sleep infinity`):

```bash
apptainer instance start \
  --writable-tmpfs \
  --bind custom_configs/sv_run/puma:/opt/gitlab/sv/puma/run \
  --bind custom_configs/sv_run/postgresql:/opt/gitlab/sv/postgresql/run \
  # ... (one bind per sub-service)
  gitlab.sif webarena_gitlab

# Launch runit in the foreground — this IS the "keep alive" mechanism
exec apptainer exec instance://webarena_gitlab \
  /opt/gitlab/embedded/bin/runsvdir /opt/gitlab/service
```

`--writable-tmpfs` gives the container an in-memory writable overlay for paths not
covered by the explicit bind mounts.

---

## Challenge 8: Services Are Not Directly Reachable from Outside the Cluster

**Problem**: SLURM compute nodes sit behind Unity's internal network. Services running
on them are not accessible from the internet or from your laptop — there is no public IP
or port forwarding.

**Solution**: Use SSH's SOCKS5 proxy mode to tunnel all browser traffic through the
Unity login node (which *can* reach the compute nodes):

```bash
# Run on your local machine:
ssh -D 1080 -N -f <username>@unity.rc.umass.edu
```

Configure your browser to use `localhost:1080` as a SOCKS5 proxy with "Proxy DNS" enabled.
All browser requests are then routed through Unity's network and can reach `gypsum-gpu049:9999`,
`gypsum-gpu055:7770`, etc. by their internal hostnames.

The `connect.sh` script automates this: it SSHes to Unity, reads all `.<svc>_node` files,
starts the SOCKS5 proxy, and prints the homepage URL.

---

## Quick Reference: Startup Checklist

```bash
# 1. From the webarena_build/ directory:
bash launch_all.sh

# 2. Wait ~5 min, then health-check:
curl -s -o /dev/null -w "%{http_code}" http://$(cat homepage/.shopping_node):7770       # expect 302
curl -s -o /dev/null -w "%{http_code}" http://$(cat homepage/.shopping_admin_node):7780 # expect 302
curl -s -o /dev/null -w "%{http_code}" http://$(cat homepage/.reddit_node):9999         # expect 200
curl -s -o /dev/null -w "%{http_code}" http://$(cat homepage/.gitlab_node):8023         # expect 302
curl -s -o /dev/null -w "%{http_code}" http://$(cat homepage/.wikipedia_node):8888      # expect 200
curl -s -o /dev/null -w "%{http_code}" http://$(cat homepage/.homepage_node):4399       # expect 200

# 3. To browse manually from your laptop:
bash connect.sh <your-unity-username>

# 4. To stop all servers:
squeue --me   # find job IDs
scancel <job1> <job2> ...
```
