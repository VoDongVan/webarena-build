# WebArena Build — Unity HPC

Deployment system for the [WebArena](https://github.com/web-arena-x/webarena) AI agent benchmark on UMass Unity HPC. Runs six web services as Apptainer containers inside SLURM batch jobs.

Unity forbids Docker (most Docker operations require root). Apptainer is the HPC-approved alternative: it runs containers rootlessly by mapping the container user to the submitting HPC user.

---

## Services

| Service | Directory | Port | SLURM resources |
|---|---|---|---|
| Magento storefront | `shopping/` | 7770 | 2 CPU / 16 GB |
| Magento admin panel | `shopping_admin/` | 7780 | 2 CPU / 16 GB |
| Reddit (Postmill) | `reddit/` | 9999 | 2 CPU / 16 GB |
| GitLab | `gitlab/` | 8023 | 2 CPU / 16 GB |
| Wikipedia (Kiwix) | `wikipedia/` | 8888 | 2 CPU / 8 GB |
| Homepage (Flask) | `homepage/` | 4399 | 1 CPU / 4 GB |

---

## Quick Start

### 1. First-time setup (once per service)

Each service directory has a `set_up.sh` that builds the Apptainer SIF from the Docker tar archive and prepares static config files. Run these from a compute node (`salloc -p cpu -c 4 --mem=32G`):

```bash
bash shopping/set_up.sh
bash shopping_admin/set_up.sh
bash reddit/set_up.sh
bash gitlab/set_up.sh
bash wikipedia/set_up.sh
# homepage needs no setup — it's a plain Python app
```

Each `set_up.sh` only needs to run once. It is safe to re-run (idempotent).

### 2. Launch all services

From the login node or any compute node:

```bash
bash launch_all.sh
```

This submits six SLURM batch jobs — one per service. Shopping and shopping_admin are automatically placed on **different nodes** (they share ports 3306 and 9200) and the script waits for that assignment before submitting the second job.

Check job status:

```bash
squeue -u $USER
```

Services take 2–10 minutes to become healthy after the job starts (GitLab takes the longest). The homepage dashboard shows live status once all `.node` files have been written.

### 3. Access from your laptop

```bash
bash connect.sh <your-unity-username>
```

This script SSHes to Unity, reads which compute nodes each service landed on, opens a SOCKS5 proxy on `localhost:1080`, and prints the homepage URL and browser setup instructions. Configure Firefox or Chrome to route traffic through the proxy, then open the homepage.

Alternatively, build an SSH tunnel manually using the node names from `squeue`.

### 4. Stop all services

```bash
bash stop_all.sh
```

Or cancel individual jobs:

```bash
scancel <job-id>
```

---

## How It Works

### Fresh-state design

Every `run_*.sh` script extracts a **pristine copy** of all database and state data directly from the read-only SIF image into `/tmp` on the compute node's local SSD at startup. The container is then started with those `/tmp` paths bind-mounted over the original paths.

```
SIF (read-only gold source)
  ↓  cp -a  (at job start)
/tmp/webarena_runtime_<svc>/   ← local SSD, writable
  ↑  bind-mounted into container
```

This means:
- Every job start produces a clean, reproducible environment.
- No persistent `webarena_data/` directories need to exist or be maintained.
- NFS lock failures are eliminated (see below).

When the SLURM job ends (normally or via `scancel`), the cleanup trap removes the `/tmp` workspace.

### Why /tmp instead of NFS (scratch3)

The NFS filesystem (`scratch3`) does not support POSIX `fcntl()` byte-range locks. Several services require file locking:

| Service | Lock type | Result on NFS |
|---|---|---|
| MySQL / InnoDB | `fcntl()` on `ibdata1` | `EIO` (I/O error), mysqld crashes |
| Elasticsearch | `NativeFSLockFactory` | `IOException`, crash-loop |
| PHP-FPM | `flock()` accept mutex in `/tmp` | `EIO`, fpm exits 255 |

The compute nodes' local `/tmp` (SSD, ~196 GB) supports all locking mechanisms correctly.

### Service discovery

After each service becomes healthy, its `run_*.sh` script writes the compute node's hostname to `homepage/.<svc>_node` (e.g. `homepage/.shopping_node`). The homepage Flask app reads these files to generate links. The test suite (`run_all_tests.sh`) and `connect.sh` also read them.

Node files are deleted at the start of `launch_all.sh` so stale hostnames from a previous run are never shown.

### SLURM keep-alive

Each SLURM script ends with `sleep infinity & wait $!` and a `trap` on `SIGTERM`/`SIGINT` that stops the Apptainer instance and cleans up `/tmp`. When `scancel` is called, SLURM sends `SIGTERM` to the batch script, which triggers this cleanup.

---

## Running Tests

After services are up, smoke-test all of them at once:

```bash
bash run_all_tests.sh
```

Or test a single service by passing its node hostname:

```bash
bash shopping/test_shopping.sh <node-hostname>
bash gitlab/test_gitlab.sh <node-hostname>
# etc.
```

Tests read the `.node` files automatically if no hostname is given. They skip Apptainer-internal checks when run from a different node (remote-node mode).

---

## Directory Layout

```
webarena_build/
├── launch_all.sh          # Submit all six SLURM jobs
├── stop_all.sh            # Cancel all running WebArena jobs
├── run_all_tests.sh       # Smoke-test all services
├── connect.sh             # Open SOCKS5 proxy and print homepage URL (run locally)
├── health_check.sh        # Poll all services until healthy (used by baseline scripts)
├── shopping/              # Magento storefront (port 7770)
├── shopping_admin/        # Magento admin panel (port 7780)
├── reddit/                # Postmill forum (port 9999)
├── gitlab/                # GitLab (port 8023)
├── wikipedia/             # Kiwix Wikipedia mirror (port 8888)
└── homepage/              # Flask dashboard + service discovery files
```

Each service directory contains:

```
<service>/
├── download.sh            # Download Docker tar and convert to SIF
├── set_up.sh              # One-time setup (build SIF, prep static configs)
├── run_<svc>.sh           # Start the service (called by the SLURM script)
├── slurm_<svc>.sh         # SLURM batch wrapper
├── test_<svc>.sh          # Smoke test
├── custom_configs/        # Config files that are bind-mounted over SIF paths
├── <svc>.sif              # Apptainer image (built by set_up.sh / download.sh)
└── webarena_data/         # Static data used by set_up.sh (not used at runtime)
```

---

## Credentials

| Service | URL path | Username | Password |
|---|---|---|---|
| Magento storefront | `/` | `emma.lopez@gmail.com` | `Password.123` |
| Magento admin | `/admin` | `admin` | `admin1234` |
| GitLab | `/` | `root` | `webarena1234!` |
| Reddit | `/` | `MarvelsGrantMan136` | `test1234` |

---

## Troubleshooting

### A service's `.node` file never appears

The job is still starting, or it failed before the readiness check passed. Check the SLURM output log:

```bash
cat <service>/slurm_<svc>.out | tail -50
```

### HTTP 502 from a service

The service started but an internal component (MySQL, PostgreSQL, PHP-FPM) hasn't come up yet, or it crashed. Check the SLURM log for the specific error. Most startup failures are transient; re-submitting the job is often sufficient.

### GitLab is slow to start

Normal — GitLab Omnibus (Rails + Sidekiq + Puma + PostgreSQL + Redis) takes 3–5 minutes to fully initialize on first boot. The health check polls for up to 10 minutes.

### shopping_admin admin panel is slow on first load

Also normal. The first request to `/admin` triggers Magento's PHP dependency injection code generation (if `magento_generated/` was empty). `run_shopping_admin.sh` pre-warms the admin panel and only writes the `.shopping_admin_node` file after it responds, so agents should not see this delay.

### Node files exist but services are unreachable

The SLURM jobs may have ended (8-hour time limit). Check with `squeue -u $USER`. Re-submit with `bash launch_all.sh`.
