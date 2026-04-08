#!/bin/bash
# run_gitlab.sh — Start the WebArena GitLab instance.
# Run this every time you want to start the site after set_up.sh has been run once.

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"
DATA_DIR="${WEBARENA_DATA_DIR:-$WORKDIR/webarena_data}"
INST="${INSTANCE_SUFFIX:-}"

echo "=== GitLab starting on $(hostname) at $(date) ==="
echo "=== SSH tunnel: ssh -L 8023:$(hostname):8023 <username>@unity.rc.umass.edu ==="

# Stop any stale instance from a previous run. If the job was killed by SIGKILL,
# the SLURM trap never fired and the instance pid file remains in ~/.apptainer/instances/,
# causing the next `apptainer instance start` to fail with "instance already exists".
apptainer instance stop webarena_gitlab 2>/dev/null || true

# PostgreSQL requires its data dir is not group/world-writable
if [ -d "$WORKDIR/webarena_data/gitlab_data/postgresql/data" ]; then
    chmod 700 "$WORKDIR/webarena_data/gitlab_data/postgresql/data"
fi
# Remove stale PostgreSQL lock files (prevents postgres startup after unclean shutdown)
rm -f "$WORKDIR/webarena_data/gitlab_data/postgresql/data/postmaster.pid"
rm -f "$WORKDIR/webarena_data/gitlab_data/postgresql/.s.PGSQL.5432"
rm -f "$WORKDIR/webarena_data/gitlab_data/postgresql/.s.PGSQL.5432.lock"

# Writable runtime dirs
chmod -R 755 "$WORKDIR/webarena_data/etc_gitlab"
chmod -R 755 "$WORKDIR/webarena_data/log_gitlab"
chmod -R 777 "$WORKDIR/webarena_data/run"
chmod -R 777 "$WORKDIR/webarena_data/tmp"

# Copy log_gitlab to local /tmp to avoid NFS file locking issues.
# svlogd uses flock() on each log directory; NFS doesn't support this reliably,
# causing "unable to lock directory: temporary failure" crash loops.
LOG_LOCAL=/tmp/webarena_log_gitlab
rm -rf "$LOG_LOCAL"
# Remove any stale lock files from NFS copy before copying
find "$WORKDIR/webarena_data/log_gitlab" -name "lock" -delete 2>/dev/null || true
cp -a "$WORKDIR/webarena_data/log_gitlab/." "$LOG_LOCAL/"
echo "Copied log_gitlab to $LOG_LOCAL ($(du -sh "$LOG_LOCAL" | cut -f1))"

SV="$WORKDIR/custom_configs/sv_run"

apptainer instance start \
  --writable-tmpfs \
  --bind "$WORKDIR/webarena_data/gitlab_data:/var/opt/gitlab" \
  --bind "$WORKDIR/webarena_data/etc_gitlab:/etc/gitlab" \
  --bind "$LOG_LOCAL:/var/log/gitlab" \
  --bind "$WORKDIR/webarena_data/run:/run" \
  --bind "$WORKDIR/webarena_data/tmp:/tmp" \
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
  gitlab.sif webarena_gitlab

echo "Instance started."
