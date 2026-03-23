#!/bin/bash
# run_gitlab.sh — Start the WebArena GitLab instance.
# Run this every time you want to start the site after set_up.sh has been run once.

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"

echo "=== GitLab starting on $(hostname) at $(date) ==="
echo "=== SSH tunnel: ssh -L 8023:$(hostname):8023 <username>@unity.rc.umass.edu ==="

# PostgreSQL requires its data dir is not group/world-writable
if [ -d "$WORKDIR/webarena_data/gitlab_data/postgresql/data" ]; then
    chmod 700 "$WORKDIR/webarena_data/gitlab_data/postgresql/data"
fi
# Remove stale postmaster.pid (prevents postgres startup)
rm -f "$WORKDIR/webarena_data/gitlab_data/postgresql/data/postmaster.pid"

# Writable runtime dirs
chmod -R 755 "$WORKDIR/webarena_data/etc_gitlab"
chmod -R 755 "$WORKDIR/webarena_data/log_gitlab"
chmod -R 777 "$WORKDIR/webarena_data/run"
chmod -R 777 "$WORKDIR/webarena_data/tmp"

SV="$WORKDIR/custom_configs/sv_run"

apptainer instance start \
  --writable-tmpfs \
  --bind "$WORKDIR/webarena_data/gitlab_data:/var/opt/gitlab" \
  --bind "$WORKDIR/webarena_data/etc_gitlab:/etc/gitlab" \
  --bind "$WORKDIR/webarena_data/log_gitlab:/var/log/gitlab" \
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
