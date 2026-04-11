#!/bin/bash
# run_gitlab.sh — Start a fresh WebArena GitLab instance.

# --- Configuration ---
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"
SIF_FILE="gitlab.sif"
INSTANCE_NAME="webarena_gitlab"
PORT=8023

# Local workspace on the node's SSD
WORKSPACE="/tmp/webarena_runtime_gitlab"
NODE=$(hostname)

# --- Cleanup Function ---
cleanup() {
    echo "Stopping instance and cleaning up local workspace..."
    apptainer instance stop $INSTANCE_NAME 2>/dev/null || true
    rm -rf "$WORKSPACE"
    exit
}
trap cleanup EXIT SIGTERM

echo "=== GitLab starting on $NODE at $(date) ==="

# --- 1. Fresh Start: Environment Prep ---
apptainer instance stop $INSTANCE_NAME 2>/dev/null || true

echo "Wiping and recreating local workspace in $WORKSPACE..."
rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE/gitlab_data" "$WORKSPACE/etc_gitlab" "$WORKSPACE/log_gitlab" \
         "$WORKSPACE/run" "$WORKSPACE/tmp"

# --- 2. Force Extraction from SIF (The "Fresh" Data) ---
# GitLab's data is large; this may take a minute.
echo "Extracting pristine data from $SIF_FILE to local SSD..."

# /var/opt/gitlab (Postgres, Redis, Repositories)
apptainer exec $SIF_FILE cp -a /var/opt/gitlab/. "$WORKSPACE/gitlab_data/"
# /etc/gitlab (Configurations)
apptainer exec $SIF_FILE cp -a /etc/gitlab/. "$WORKSPACE/etc_gitlab/"
# /var/log/gitlab (Logs)
apptainer exec $SIF_FILE cp -a /var/log/gitlab/. "$WORKSPACE/log_gitlab/"

# Fix PostgreSQL permissions immediately after extraction
if [ -d "$WORKSPACE/gitlab_data/postgresql/data" ]; then
    chmod 700 "$WORKSPACE/gitlab_data/postgresql/data"
fi

# Broad permissions for other runtime dirs to avoid service start failures
chmod -R 777 "$WORKSPACE/run" "$WORKSPACE/tmp" "$WORKSPACE/log_gitlab"

# --- 3. Configuration Setup ---
# Patch gitlab.rb if necessary to point to the current hostname/port
# (Optional: Only if your GitLab setup requires an external_url update)
# sed -i "s|external_url .*|external_url 'http://$NODE:$PORT'|g" "$WORKSPACE/etc_gitlab/gitlab.rb"

# --- 4. Start the Fresh Instance ---
echo "Starting Apptainer instance..."

SV="$WORKDIR/custom_configs/sv_run"

apptainer instance start \
  --writable-tmpfs \
  --bind "$WORKSPACE/gitlab_data:/var/opt/gitlab" \
  --bind "$WORKSPACE/etc_gitlab:/etc/gitlab" \
  --bind "$WORKSPACE/log_gitlab:/var/log/gitlab" \
  --bind "$WORKSPACE/run:/run" \
  --bind "$WORKSPACE/tmp:/tmp" \
  --bind "$SV/alertmanager:/opt/gitlab/sv/alertmanager/run" \
  --bind "$SV/gitaly:/opt/gitlab/sv/gitaly/run" \
  --bind "$SV/gitlab-exporter:/opt/gitlab/sv/gitlab-exporter/run" \
  --bind "$SV/gitlab-kas:/opt/gitlab/sv/gitlab-kas/run" \
  --bind "$SV/gitlab-workhorse:/opt/gitlab/sv/gitlab-workhorse/run" \
  --bind "$SV/postgres-exporter:/opt/gitlab/sv/postgres-exporter/run" \
  --bind "$SV/postgresql:/opt/gitlab/sv/postgresql/run" \
  --bind "$SV/prometheus:/opt/gitlab/sv/prometheus/run" \
  --bind "$SV/puma:/opt/gitlab/sv/puma/run" \
  --bind "$SV/redis:/opt/gitlab/sv/redis/run" \
  --bind "$SV/redis-exporter:/opt/gitlab/sv/redis-exporter/run" \
  --bind "$SV/sidekiq:/opt/gitlab/sv/sidekiq/run" \
  $SIF_FILE $INSTANCE_NAME

echo "Instance started. Omnibus services are initializing..."

# --- 5. Service Readiness ---
echo "Waiting for GitLab to respond on http://$NODE:$PORT ..."
# GitLab takes a LONG time to start (often 2-3 minutes)
for i in $(seq 1 60); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8023/-/health || echo "000")
    if [ "$CODE" = "200" ]; then
        echo "GitLab is healthy (HTTP 200)."
        break
    fi
    echo "  Attempt $i/60: HTTP $CODE (GitLab is still warming up), waiting 10s..."
    sleep 10
done

# Update service discovery for the homepage
echo "$NODE" > "$WORKDIR/../homepage/.gitlab_node"

echo "=== GitLab Freshly Deployed ==="
echo "URL: http://$NODE:$PORT"
echo "SSH tunnel: ssh -L $PORT:$NODE:$PORT <username>@unity.rc.umass.edu"

# Keep alive for SLURM
wait

# #!/bin/bash
# # run_gitlab.sh — Start the WebArena GitLab instance.
# # Run this every time you want to start the site after set_up.sh has been run once.

# WORKDIR="$(cd "$(dirname "$0")" && pwd)"
# cd "$WORKDIR"
# DATA_DIR="${WEBARENA_DATA_DIR:-$WORKDIR/webarena_data}"
# INST="${INSTANCE_SUFFIX:-}"

# echo "=== GitLab starting on $(hostname) at $(date) ==="
# echo "=== SSH tunnel: ssh -L 8023:$(hostname):8023 <username>@unity.rc.umass.edu ==="

# # Stop any stale instance from a previous run. If the job was killed by SIGKILL,
# # the SLURM trap never fired and the instance pid file remains in ~/.apptainer/instances/,
# # causing the next `apptainer instance start` to fail with "instance already exists".
# apptainer instance stop webarena_gitlab 2>/dev/null || true

# # PostgreSQL requires its data dir is not group/world-writable
# if [ -d "$WORKDIR/webarena_data/gitlab_data/postgresql/data" ]; then
#     chmod 700 "$WORKDIR/webarena_data/gitlab_data/postgresql/data"
# fi
# # Remove stale PostgreSQL lock files (prevents postgres startup after unclean shutdown)
# rm -f "$WORKDIR/webarena_data/gitlab_data/postgresql/data/postmaster.pid"
# rm -f "$WORKDIR/webarena_data/gitlab_data/postgresql/.s.PGSQL.5432"
# rm -f "$WORKDIR/webarena_data/gitlab_data/postgresql/.s.PGSQL.5432.lock"

# # Writable runtime dirs
# chmod -R 755 "$WORKDIR/webarena_data/etc_gitlab"
# chmod -R 755 "$WORKDIR/webarena_data/log_gitlab"
# chmod -R 777 "$WORKDIR/webarena_data/run"
# chmod -R 777 "$WORKDIR/webarena_data/tmp"

# # Copy log_gitlab to local /tmp to avoid NFS file locking issues.
# # svlogd uses flock() on each log directory; NFS doesn't support this reliably,
# # causing "unable to lock directory: temporary failure" crash loops.
# LOG_LOCAL=/tmp/webarena_log_gitlab
# rm -rf "$LOG_LOCAL"
# # Remove any stale lock files from NFS copy before copying
# find "$WORKDIR/webarena_data/log_gitlab" -name "lock" -delete 2>/dev/null || true
# cp -a "$WORKDIR/webarena_data/log_gitlab/." "$LOG_LOCAL/"
# echo "Copied log_gitlab to $LOG_LOCAL ($(du -sh "$LOG_LOCAL" | cut -f1))"

# SV="$WORKDIR/custom_configs/sv_run"

# apptainer instance start \
#   --writable-tmpfs \
#   --bind "$WORKDIR/webarena_data/gitlab_data:/var/opt/gitlab" \
#   --bind "$WORKDIR/webarena_data/etc_gitlab:/etc/gitlab" \
#   --bind "$LOG_LOCAL:/var/log/gitlab" \
#   --bind "$WORKDIR/webarena_data/run:/run" \
#   --bind "$WORKDIR/webarena_data/tmp:/tmp" \
#   --bind "$SV/alertmanager:/opt/gitlab/sv/alertmanager/run" \
#   --bind "$SV/gitaly:/opt/gitlab/sv/gitaly/run" \
#   --bind "$SV/gitlab-exporter:/opt/gitlab/sv/gitlab-exporter/run" \
#   --bind "$SV/gitlab-kas:/opt/gitlab/sv/gitlab-kas/run" \
#   --bind "$SV/gitlab-workhorse:/opt/gitlab/sv/gitlab-workhorse/run" \
#   --bind "$SV/postgres-exporter:/opt/gitlab/sv/postgres-exporter/run" \
#   --bind "$SV/postgresql:/opt/gitlab/sv/postgresql/run" \
#   --bind "$SV/prometheus:/opt/gitlab/sv/prometheus/run" \
#   --bind "$SV/puma:/opt/gitlab/sv/puma/run" \
#   --bind "$SV/redis:/opt/gitlab/sv/redis/run" \
#   --bind "$SV/redis-exporter:/opt/gitlab/sv/redis-exporter/run" \
#   --bind "$SV/sidekiq:/opt/gitlab/sv/sidekiq/run" \
#   gitlab.sif webarena_gitlab

# echo "Instance started."
