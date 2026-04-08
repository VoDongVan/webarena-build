#!/bin/bash
# run_shopping_admin.sh — Start the WebArena shopping_admin instance.
# Run this every time you want to start the site after set_up.sh has been run once.

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"
DATA_DIR="${WEBARENA_DATA_DIR:-$WORKDIR/webarena_data}"
INST="${INSTANCE_SUFFIX:-}"

echo "=== Shopping Admin starting on $(hostname) at $(date) ==="
echo "=== SSH tunnel: ssh -L 7780:$(hostname):7780 <username>@unity.rc.umass.edu ==="

# Record which node we're on so the homepage and test scripts can find us.
echo "$(hostname)" > "$WORKDIR/../homepage/.shopping_admin_node"

# Stop any stale instance from a previous run. If the job was killed by SIGKILL,
# the SLURM trap never fired and the instance pid file remains in ~/.apptainer/instances/,
# causing the next `apptainer instance start` to fail with "instance already exists".
apptainer instance stop webarena_shopping_admin 2>/dev/null || true

chmod -R 777 "$DATA_DIR"

# --- Stale file cleanup (SLURM kills leave these; they prevent clean restart) ---
# MariaDB: DDL recovery artifacts, temp files, PIDs, socket
# NOTE: do NOT delete ib_logfile0/1 — those are InnoDB redo logs needed for
# crash recovery after an unclean shutdown. Deleting them causes MySQL to fail
# to start when data files are dirty (502 on every restart).
rm -f "$WORKDIR/webarena_data/mysql/ibtmp1"
rm -f "$WORKDIR/webarena_data/mysql/aria_log.00000001"
rm -f "$WORKDIR/webarena_data/mysql/aria_log_control"
rm -f "$WORKDIR/webarena_data/mysql/ddl_recovery.log"
rm -f "$WORKDIR/webarena_data/mysql/ddl_recovery-backup.log"
rm -f "$WORKDIR/webarena_data/mysql/"*.pid
rm -f "$WORKDIR/webarena_data/run/mysqld/mysqld.pid"
rm -f "$WORKDIR/webarena_data/run/mysqld/mysqld.sock"
# Nginx, cron, supervisord PIDs and sockets
rm -f "$WORKDIR/webarena_data/run/nginx.pid"
rm -f "$WORKDIR/webarena_data/run/crond.pid"
rm -f "$WORKDIR/webarena_data/run/supervisord.sock"
rm -f "$WORKDIR/webarena_data/container.pid"
# NFS silly-rename files
find "$WORKDIR/webarena_data/run" -name ".nfs*" -delete 2>/dev/null || true
# Elasticsearch: clean both esdata/ and es_data/ (both present from prior runs)
rm -f "$WORKDIR/webarena_data/esdata/nodes/0/node.lock"
find "$WORKDIR/webarena_data/esdata" -name "write.lock" -delete 2>/dev/null || true
rm -f "$WORKDIR/webarena_data/es_data/nodes/0/node.lock"
find "$WORKDIR/webarena_data/es_data" -name "write.lock" -delete 2>/dev/null || true
# Magento: cache regeneration lock
rm -f "$WORKDIR/webarena_data/magento_var/.regenerate.lock"

# Initialize MySQL data directory from SIF if not already done.
# This is required on first run (or if webarena_data/mysql/ was deleted).
# Apptainer will abort with a fatal mount error if the bind source doesn't exist.
if [ ! -d "$WORKDIR/webarena_data/mysql/mysql" ]; then
    echo "Initializing MySQL data from SIF..."
    mkdir -p "$WORKDIR/webarena_data/mysql"
    apptainer exec shopping_admin.sif cp -a /var/lib/mysql/. "$WORKDIR/webarena_data/mysql/"
    chmod -R 777 "$WORKDIR/webarena_data/mysql"
fi

# Copy ES data to local /tmp to avoid NFS file locking issues.
# NFS (scratch3) does not support fcntl() locks; Java's NativeFSLockFactory
# throws IOException instead of returning null, so ES crash-loops indefinitely.
# /tmp on the compute node is local storage — locking works there.
ES_LOCAL=/tmp/webarena_esdata_shopping_admin
rm -rf "$ES_LOCAL"
cp -a "$WORKDIR/webarena_data/esdata/." "$ES_LOCAL/"
echo "Copied ES data to $ES_LOCAL ($(du -sh "$ES_LOCAL" | cut -f1))"

# Ensure nginx tmp dirs exist (nginx won't start without these)
mkdir -p "$WORKDIR/webarena_data/nginx/tmp/client_body"
mkdir -p "$WORKDIR/webarena_data/nginx/tmp/proxy"
mkdir -p "$WORKDIR/webarena_data/nginx/tmp/fastcgi"
mkdir -p "$WORKDIR/webarena_data/nginx/tmp/uwsgi"
mkdir -p "$WORKDIR/webarena_data/nginx/tmp/scgi"

# Re-extract + re-patch nginx vhost each run (handles node changes)
apptainer exec shopping_admin.sif cat /etc/nginx/conf.d/default.conf > "$(pwd)/custom_configs/conf_default.conf"
sed -i 's/listen 80/listen 7780/g' "$(pwd)/custom_configs/conf_default.conf"
sed -i 's/listen \[::\]:80/listen \[::\]:7780/g' "$(pwd)/custom_configs/conf_default.conf"

# Write a minimal entrypoint that bypasses docker-entrypoint.sh (which requires root for chown)
cat > "$(pwd)/custom_configs/start.sh" << 'EOF'
#!/bin/bash
exec supervisord -n -c /etc/supervisord.conf
EOF
chmod +x "$(pwd)/custom_configs/start.sh"

# Ensure MySQL log directory exists (needed by custom mysql.ini)
mkdir -p "$WORKDIR/webarena_data/log/mysql"

# Copy MySQL data to local /tmp to avoid NFS file locking issues.
# InnoDB uses fcntl() locks on ibdata1; NFS (scratch3) returns EIO (5) for these.
# /tmp on the compute node is local storage — locking works there.
MYSQL_LOCAL=/tmp/webarena_mysql_shopping_admin
rm -rf "$MYSQL_LOCAL"
cp -a "$WORKDIR/webarena_data/mysql/." "$MYSQL_LOCAL/"
echo "Copied MySQL data to $MYSQL_LOCAL ($(du -sh "$MYSQL_LOCAL" | cut -f1))"

# Create a local /run equivalent to avoid NFS lock issues for PHP-FPM, nginx, etc.
# /run bind-mounted from NFS causes "Cannot create lock - I/O error (5)" in PHP-FPM.
RUN_LOCAL=/tmp/webarena_run_shopping_admin
rm -rf "$RUN_LOCAL"
mkdir -p "$RUN_LOCAL/mysqld" "$RUN_LOCAL/nginx" "$RUN_LOCAL/php-fpm" "$RUN_LOCAL/redis"
chmod 777 "$RUN_LOCAL" "$RUN_LOCAL/mysqld" "$RUN_LOCAL/nginx" "$RUN_LOCAL/php-fpm" "$RUN_LOCAL/redis"
# .init marks MySQL as already initialized so docker-entrypoint.sh skips mysql_install_db
touch "$RUN_LOCAL/mysqld/.init"

# Create a local /tmp for the container to avoid NFS lock issues.
# PHP-FPM creates its accept lock in /tmp; NFS returns EIO (5) for fcntl() locks.
TMP_LOCAL=/tmp/webarena_tmp_shopping_admin
rm -rf "$TMP_LOCAL"
mkdir -p "$TMP_LOCAL"
chmod 1777 "$TMP_LOCAL"

apptainer instance start \
  --bind "$(pwd)/custom_configs/start.sh:/docker-entrypoint.sh" \
  --bind "$(pwd)/custom_configs/supervisord.conf:/etc/supervisord.conf" \
  --bind "$(pwd)/custom_configs/nginx.conf:/etc/nginx/nginx.conf" \
  --bind "$(pwd)/custom_configs/conf_default.conf:/etc/nginx/conf.d/default.conf" \
  --bind "$(pwd)/custom_configs/mysql.ini:/etc/supervisor.d/mysql.ini" \
  --bind "$(pwd)/webarena_data/nginx:/var/lib/nginx" \
  --bind "$MYSQL_LOCAL:/var/lib/mysql" \
  --bind "$(pwd)/webarena_data/redis:/var/lib/redis" \
  --bind "$TMP_LOCAL:/tmp" \
  --bind "$(pwd)/webarena_data/log:/var/log" \
  --bind "$RUN_LOCAL:/run" \
  --bind "$ES_LOCAL:/usr/share/java/elasticsearch/data" \
  --bind "$(pwd)/webarena_data/eslog:/usr/share/java/elasticsearch/logs" \
  --bind "$(pwd)/webarena_data/es_config:/usr/share/java/elasticsearch/config" \
  --bind "$(pwd)/webarena_data/magento_var:/var/www/magento2/var" \
  --bind "$(pwd)/webarena_data/magento_generated:/var/www/magento2/generated" \
  shopping_admin.sif webarena_shopping_admin

# The SIF's %startscript is empty (Docker image had no startscript section).
# We must launch supervisord explicitly after the instance namespace is up.
echo "Instance started. Launching supervisord..."
apptainer exec instance://webarena_shopping_admin \
  supervisord -n -c /etc/supervisord.conf &
sleep 2
echo "Waiting for services to become ready..."

# Wait for MySQL to accept connections
echo "Waiting for MySQL..."
for i in $(seq 1 60); do
    if apptainer exec instance://webarena_shopping_admin \
         mysql -h127.0.0.1 -umagentouser -pMyPassword -e "SELECT 1" magentodb &>/dev/null 2>&1; then
        echo "MySQL ready."
        break
    fi
    echo "  attempt $i/60, waiting 5s..."
    sleep 5
done

# Update Magento base URL to actual node hostname so SOCKS5 proxy works
NODE=$(hostname)
echo "Updating Magento base URL to http://$NODE:7780/ ..."
apptainer exec instance://webarena_shopping_admin \
  mysql -h127.0.0.1 -umagentouser -pMyPassword magentodb -e \
  "UPDATE core_config_data SET value='http://$NODE:7780/' WHERE path LIKE 'web/%base_url%';"

echo "Flushing Magento cache..."
apptainer exec instance://webarena_shopping_admin \
  php /var/www/magento2/bin/magento cache:flush

echo "=== Shopping Admin ready at http://$NODE:7780 ==="
