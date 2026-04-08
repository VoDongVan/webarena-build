#!/bin/bash
# run_reddit.sh — Start the WebArena Reddit (Postmill) instance.
# Run this every time you want to start the site after set_up.sh has been run once.

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"

echo "=== Reddit (Postmill) starting on $(hostname) at $(date) ==="
echo "=== SSH tunnel: ssh -L 9999:$(hostname):9999 <username>@unity.rc.umass.edu ==="

# Stop any stale instance from a previous run. If the job was killed by SIGKILL,
# the SLURM trap never fired and the instance pid file remains in ~/.apptainer/instances/,
# causing the next `apptainer instance start` to fail with "instance already exists".
apptainer instance stop webarena_reddit 2>/dev/null || true

# PostgreSQL requires its data dir is not group/world-writable
chmod -R 700 "$WORKDIR/webarena_data/pgsql"
# Remove stale postmaster.pid and socket lock file if present (prevents postgres startup)
rm -f "$WORKDIR/webarena_data/pgsql/postmaster.pid"
rm -f "$WORKDIR/webarena_data/run/postgresql/.s.PGSQL.5432.lock"
# Recover corrupted WAL (caused by unclean shutdown / SLURM job kill mid-write)
if [ -f "$WORKDIR/webarena_data/pgsql/global/pg_control" ]; then
    echo "=== Running pg_resetwal to recover any corrupted WAL ==="
    apptainer exec \
        --bind "$WORKDIR/webarena_data/pgsql:/usr/local/pgsql/data" \
        reddit.sif /usr/bin/pg_resetwal -f /usr/local/pgsql/data 2>&1 || true
fi
# Remove stale NFS silly-rename files and php-fpm socket/pid (cause php-fpm exit 255 on restart)
rm -f "$WORKDIR/webarena_data/run/.nfs"* 2>/dev/null || true
rm -f "$WORKDIR/webarena_data/run/php-fpm"* 2>/dev/null || true
# Clear Postmill/Symfony cache (stale cache from a prior PHP session causes php-fpm exit 255)
rm -rf "$WORKDIR/webarena_data/postmill_var/cache/"*
# Everything else should be freely writable
chmod -R 777 "$WORKDIR/webarena_data/run"
chmod -R 777 "$WORKDIR/webarena_data/log"
chmod -R 777 "$WORKDIR/webarena_data/tmp"
chmod -R 777 "$WORKDIR/webarena_data/postmill_var"

# Ensure nginx tmp dirs exist inside /run (bind-mounted from NFS, but nginx uses
# rename() not flock(), so NFS is safe here). We intentionally do NOT bind-mount
# NFS over /tmp — php-fpm creates an accept mutex lock in /tmp using flock(),
# which NFS rejects with EIO. The container's own overlay /tmp is local to the
# compute node and avoids this.
mkdir -p "$WORKDIR/webarena_data/run/nginx-tmp/client_body"
mkdir -p "$WORKDIR/webarena_data/run/nginx-tmp/proxy"
mkdir -p "$WORKDIR/webarena_data/run/nginx-tmp/fastcgi"
mkdir -p "$WORKDIR/webarena_data/run/nginx-tmp/uwsgi"
mkdir -p "$WORKDIR/webarena_data/run/nginx-tmp/scgi"
mkdir -p "$WORKDIR/webarena_data/run/nginx"
mkdir -p "$WORKDIR/webarena_data/run/postgresql"
mkdir -p "$WORKDIR/webarena_data/log/nginx"

# Re-extract + re-patch nginx vhost each run
apptainer exec reddit.sif cat /etc/nginx/conf.d/default.conf > "$WORKDIR/custom_configs/conf_default.conf"
sed -i 's/listen 80/listen 9999/g' "$WORKDIR/custom_configs/conf_default.conf"
sed -i 's/listen \[::\]:80/listen \[::\]:9999/g' "$WORKDIR/custom_configs/conf_default.conf"

# Patch main nginx.conf to redirect temp dirs into /run/nginx-tmp/ (NFS-safe for nginx).
# /var/tmp/nginx does not exist in this SIF, so we must redirect temp paths.
apptainer exec reddit.sif cat /etc/nginx/nginx.conf > "$WORKDIR/custom_configs/nginx.conf"
sed -i '/http {/a\  client_body_temp_path /run/nginx-tmp/client_body;\n  proxy_temp_path /run/nginx-tmp/proxy;\n  fastcgi_temp_path /run/nginx-tmp/fastcgi;\n  uwsgi_temp_path /run/nginx-tmp/uwsgi;\n  scgi_temp_path /run/nginx-tmp/scgi;' \
    "$WORKDIR/custom_configs/nginx.conf"

# Re-write start.sh each run
cat > "$WORKDIR/custom_configs/start.sh" << 'EOF'
#!/bin/sh
exec supervisord -n -j /supervisord.pid -c /etc/supervisord.conf
EOF
chmod +x "$WORKDIR/custom_configs/start.sh"

apptainer instance start \
  --bind "$WORKDIR/custom_configs/start.sh:/docker-entrypoint.sh" \
  --bind "$WORKDIR/custom_configs/pgsql.ini:/etc/supervisor.d/pgsql.ini" \
  --bind "$WORKDIR/custom_configs/nginx.conf:/etc/nginx/nginx.conf" \
  --bind "$WORKDIR/custom_configs/conf_default.conf:/etc/nginx/conf.d/default.conf" \
  --bind "$WORKDIR/webarena_data/pgsql:/usr/local/pgsql/data" \
  --bind "$WORKDIR/webarena_data/run:/run" \
  --bind "$WORKDIR/webarena_data/run:/var/run" \
  --bind "$WORKDIR/webarena_data/log:/var/log" \
  --bind "$WORKDIR/webarena_data/postmill_var:/var/www/html/var" \
  reddit.sif webarena_reddit

# The SIF's %startscript is empty — launch supervisord explicitly
echo "Instance started. Launching supervisord..."
apptainer exec instance://webarena_reddit \
  supervisord -n -j /supervisord.pid -c /etc/supervisord.conf &

echo "Waiting for services to become ready..."
for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9999 2>/dev/null || echo "000")
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
        echo "Services ready (HTTP $CODE)."
        break
    fi
    echo "Attempt $i/30: HTTP $CODE, waiting 5s..."
    sleep 5
done
