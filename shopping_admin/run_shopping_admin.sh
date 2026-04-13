#!/bin/bash
# run_shopping_admin.sh — Start a fresh WebArena shopping_admin instance.

# --- Configuration ---
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"
SIF_FILE="shopping_admin.sif"
INSTANCE_NAME="webarena_shopping_admin"
PORT=7780

# Local workspace on the node's SSD (196GB available on /tmp)
WORKSPACE="/tmp/webarena_runtime_shopping_admin"
NODE=$(hostname)

# --- Cleanup Function ---
cleanup() {
    echo "Stopping instance and cleaning up local workspace..."
    apptainer instance stop $INSTANCE_NAME 2>/dev/null || true
    rm -rf "$WORKSPACE"
    exit
}
trap cleanup EXIT SIGTERM

echo "=== Shopping Admin starting on $NODE at $(date) ==="

# --- 1. Fresh Start: Environment Prep ---
apptainer instance stop $INSTANCE_NAME 2>/dev/null || true

echo "Wiping and recreating local workspace in $WORKSPACE..."
rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE/mysql" "$WORKSPACE/esdata" "$WORKSPACE/run/mysqld" \
         "$WORKSPACE/run/nginx" "$WORKSPACE/run/php-fpm" "$WORKSPACE/run/redis" \
         "$WORKSPACE/tmp" "$WORKSPACE/log/mysql" "$WORKSPACE/magento_var" \
         "$WORKSPACE/magento_generated" \
         "$WORKSPACE/nginx_tmp/tmp/client_body" \
         "$WORKSPACE/nginx_tmp/tmp/proxy" \
         "$WORKSPACE/nginx_tmp/tmp/fastcgi" \
         "$WORKSPACE/nginx_tmp/tmp/uwsgi" \
         "$WORKSPACE/nginx_tmp/tmp/scgi" \
         "$WORKSPACE/nginx_tmp/logs" \
         "$WORKSPACE/log/nginx" \
         "$WORKSPACE/redis" "$WORKSPACE/eslog" "$WORKSPACE/es_config" \
         "$(pwd)/custom_configs"

chmod -R 777 "$WORKSPACE"
touch "$WORKSPACE/run/mysqld/.init"

# --- 2. Force Extraction from SIF (Gold Source) ---
echo "Extracting pristine data from $SIF_FILE..."

# MySQL
apptainer exec $SIF_FILE cp -a /var/lib/mysql/. "$WORKSPACE/mysql/"
# Elasticsearch
apptainer exec $SIF_FILE cp -a /usr/share/java/elasticsearch/data/. "$WORKSPACE/esdata/" 2>/dev/null || true
apptainer exec $SIF_FILE cp -a /usr/share/java/elasticsearch/config/. "$WORKSPACE/es_config/" 2>/dev/null || true
# Magento
apptainer exec $SIF_FILE cp -a /var/www/magento2/var/. "$WORKSPACE/magento_var/" 2>/dev/null || true
# Redis
apptainer exec $SIF_FILE cp -a /var/lib/redis/. "$WORKSPACE/redis/" 2>/dev/null || true

# --- 3. Configuration & Entrypoint Setup ---
echo "Patching configurations for port $PORT..."

# Patch Nginx
apptainer exec $SIF_FILE cat /etc/nginx/conf.d/default.conf > "$(pwd)/custom_configs/conf_default.conf"
sed -i "s/listen 80/listen $PORT/g" "$(pwd)/custom_configs/conf_default.conf"
sed -i "s/listen \[::\]:80/listen \[::\]:$PORT/g" "$(pwd)/custom_configs/conf_default.conf"

# Create the startup bypass script (Supervisord runner)
cat > "$(pwd)/custom_configs/start.sh" << 'EOF'
#!/bin/bash
exec supervisord -n -c /etc/supervisord.conf
EOF
chmod +x "$(pwd)/custom_configs/start.sh"

# --- 4. Start the Fresh Instance ---
echo "Starting Apptainer instance..."

apptainer instance start \
  --bind "$(pwd)/custom_configs/start.sh:/docker-entrypoint.sh" \
  --bind "$(pwd)/custom_configs/supervisord.conf:/etc/supervisord.conf" \
  --bind "$(pwd)/custom_configs/nginx.conf:/etc/nginx/nginx.conf" \
  --bind "$(pwd)/custom_configs/conf_default.conf:/etc/nginx/conf.d/default.conf" \
  --bind "$(pwd)/custom_configs/mysql.ini:/etc/supervisor.d/mysql.ini" \
  --bind "$WORKSPACE/nginx_tmp:/var/lib/nginx" \
  --bind "$WORKSPACE/mysql:/var/lib/mysql" \
  --bind "$WORKSPACE/redis:/var/lib/redis" \
  --bind "$WORKSPACE/tmp:/tmp" \
  --bind "$WORKSPACE/log:/var/log" \
  --bind "$WORKSPACE/run:/run" \
  --bind "$WORKSPACE/esdata:/usr/share/java/elasticsearch/data" \
  --bind "$WORKSPACE/eslog:/usr/share/java/elasticsearch/logs" \
  --bind "$WORKSPACE/es_config:/usr/share/java/elasticsearch/config" \
  --bind "$WORKSPACE/magento_var:/var/www/magento2/var" \
  --bind "$WORKSPACE/magento_generated:/var/www/magento2/generated" \
  $SIF_FILE $INSTANCE_NAME

# Launch services
echo "Launching supervisord..."
apptainer exec instance://$INSTANCE_NAME /docker-entrypoint.sh &
sleep 5

# --- 5. Service Readiness ---
echo "Waiting for MySQL on $NODE..."
for i in $(seq 1 60); do
    if apptainer exec instance://$INSTANCE_NAME \
         mysql -h127.0.0.1 -umagentouser -pMyPassword -e "SELECT 1" magentodb &>/dev/null 2>&1; then
        echo "MySQL ready."
        break
    fi
    [ $i -eq 60 ] && echo "MySQL timeout." && exit 1
    sleep 5
done

# Update Magento Base URL
echo "Updating Magento base URL to http://$NODE:$PORT/ ..."
apptainer exec instance://$INSTANCE_NAME \
  mysql -h127.0.0.1 -umagentouser -pMyPassword magentodb -e \
  "UPDATE core_config_data SET value='http://$NODE:$PORT/' WHERE path LIKE 'web/%base_url%';"

echo "Flushing Magento cache..."
apptainer exec instance://$INSTANCE_NAME \
  php /var/www/magento2/bin/magento cache:flush

echo "Waiting for Magento HTTP readiness..."
for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://$NODE:$PORT/" || echo 000)

    if [[ "${code:0:1}" == "2" ]]; then
        echo "Magento HTTP ready (code=$code)"
        break
    fi

    echo "Waiting... (HTTP $code)"
    sleep 5

    if [[ $i -eq 60 ]]; then
        echo "Magento HTTP readiness timeout"
        exit 1
    fi
done

# Finalize readiness for service discovery
echo "$NODE" > "$WORKDIR/../homepage/.shopping_admin_node"

echo "=== Shopping Admin Freshly Deployed ==="
echo "URL: http://$NODE:$PORT"
echo "SSH tunnel: ssh -L $PORT:$NODE:$PORT <username>@unity.rc.umass.edu"

# Keep the script running so the trap doesn't trigger immediately
# If running via SLURM, this will keep the allocation alive
sleep infinity & wait $!




# #!/bin/bash
# # run_shopping_admin.sh — Start the WebArena shopping_admin instance.
# # Run this every time you want to start the site after set_up.sh has been run once.

# WORKDIR="$(cd "$(dirname "$0")" && pwd)"
# cd "$WORKDIR"
# DATA_DIR="${WEBARENA_DATA_DIR:-$WORKDIR/webarena_data}"
# INST="${INSTANCE_SUFFIX:-}"

# echo "=== Shopping Admin starting on $(hostname) at $(date) ==="
# echo "=== SSH tunnel: ssh -L 7780:$(hostname):7780 <username>@unity.rc.umass.edu ==="

# # NOTE: .shopping_admin_node is written AFTER Magento is fully ready (see bottom of script).
# # Writing it here would cause the health check to see the node before MySQL/cache are ready,
# # resulting in Playwright timeouts waiting for the login form.

# # Stop any stale instance from a previous run. If the job was killed by SIGKILL,
# # the SLURM trap never fired and the instance pid file remains in ~/.apptainer/instances/,
# # causing the next `apptainer instance start` to fail with "instance already exists".
# apptainer instance stop webarena_shopping_admin 2>/dev/null || true

# chmod -R 777 "$DATA_DIR"

# # --- Stale file cleanup (SLURM kills leave these; they prevent clean restart) ---
# # MariaDB: DDL recovery artifacts, temp files, PIDs, socket
# # NOTE: do NOT delete ib_logfile0/1 — those are InnoDB redo logs needed for
# # crash recovery after an unclean shutdown. Deleting them causes MySQL to fail
# # to start when data files are dirty (502 on every restart).
# rm -f "$WORKDIR/webarena_data/mysql/ibtmp1"
# rm -f "$WORKDIR/webarena_data/mysql/aria_log.00000001"
# rm -f "$WORKDIR/webarena_data/mysql/aria_log_control"
# rm -f "$WORKDIR/webarena_data/mysql/ddl_recovery.log"
# rm -f "$WORKDIR/webarena_data/mysql/ddl_recovery-backup.log"
# rm -f "$WORKDIR/webarena_data/mysql/"*.pid
# rm -f "$WORKDIR/webarena_data/run/mysqld/mysqld.pid"
# rm -f "$WORKDIR/webarena_data/run/mysqld/mysqld.sock"
# # Nginx, cron, supervisord PIDs and sockets
# rm -f "$WORKDIR/webarena_data/run/nginx.pid"
# rm -f "$WORKDIR/webarena_data/run/crond.pid"
# rm -f "$WORKDIR/webarena_data/run/supervisord.sock"
# rm -f "$WORKDIR/webarena_data/container.pid"
# # NFS silly-rename files
# find "$WORKDIR/webarena_data/run" -name ".nfs*" -delete 2>/dev/null || true
# # Elasticsearch: clean both esdata/ and es_data/ (both present from prior runs)
# rm -f "$WORKDIR/webarena_data/esdata/nodes/0/node.lock"
# find "$WORKDIR/webarena_data/esdata" -name "write.lock" -delete 2>/dev/null || true
# rm -f "$WORKDIR/webarena_data/es_data/nodes/0/node.lock"
# find "$WORKDIR/webarena_data/es_data" -name "write.lock" -delete 2>/dev/null || true
# # Magento: cache regeneration lock
# rm -f "$WORKDIR/webarena_data/magento_var/.regenerate.lock"

# # Initialize MySQL data directory from SIF if not already done.
# # This is required on first run (or if webarena_data/mysql/ was deleted).
# # Apptainer will abort with a fatal mount error if the bind source doesn't exist.
# if [ ! -d "$WORKDIR/webarena_data/mysql/mysql" ]; then
#     echo "Initializing MySQL data from SIF..."
#     mkdir -p "$WORKDIR/webarena_data/mysql"
#     apptainer exec shopping_admin.sif cp -a /var/lib/mysql/. "$WORKDIR/webarena_data/mysql/"
#     chmod -R 777 "$WORKDIR/webarena_data/mysql"
# fi

# # Copy ES data to local /tmp to avoid NFS file locking issues.
# # NFS (scratch3) does not support fcntl() locks; Java's NativeFSLockFactory
# # throws IOException instead of returning null, so ES crash-loops indefinitely.
# # /tmp on the compute node is local storage — locking works there.
# ES_LOCAL=/tmp/webarena_esdata_shopping_admin
# rm -rf "$ES_LOCAL"
# cp -a "$WORKDIR/webarena_data/esdata/." "$ES_LOCAL/"
# echo "Copied ES data to $ES_LOCAL ($(du -sh "$ES_LOCAL" | cut -f1))"

# # Ensure nginx tmp dirs exist (nginx won't start without these)
# mkdir -p "$WORKDIR/webarena_data/nginx/tmp/client_body"
# mkdir -p "$WORKDIR/webarena_data/nginx/tmp/proxy"
# mkdir -p "$WORKDIR/webarena_data/nginx/tmp/fastcgi"
# mkdir -p "$WORKDIR/webarena_data/nginx/tmp/uwsgi"
# mkdir -p "$WORKDIR/webarena_data/nginx/tmp/scgi"

# # Re-extract + re-patch nginx vhost each run (handles node changes)
# apptainer exec shopping_admin.sif cat /etc/nginx/conf.d/default.conf > "$(pwd)/custom_configs/conf_default.conf"
# sed -i 's/listen 80/listen 7780/g' "$(pwd)/custom_configs/conf_default.conf"
# sed -i 's/listen \[::\]:80/listen \[::\]:7780/g' "$(pwd)/custom_configs/conf_default.conf"

# # Write a minimal entrypoint that bypasses docker-entrypoint.sh (which requires root for chown)
# cat > "$(pwd)/custom_configs/start.sh" << 'EOF'
# #!/bin/bash
# exec supervisord -n -c /etc/supervisord.conf
# EOF
# chmod +x "$(pwd)/custom_configs/start.sh"

# # Ensure MySQL log directory exists (needed by custom mysql.ini)
# mkdir -p "$WORKDIR/webarena_data/log/mysql"

# # Copy MySQL data to local /tmp to avoid NFS file locking issues.
# # InnoDB uses fcntl() locks on ibdata1; NFS (scratch3) returns EIO (5) for these.
# # /tmp on the compute node is local storage — locking works there.
# MYSQL_LOCAL=/tmp/webarena_mysql_shopping_admin
# rm -rf "$MYSQL_LOCAL"
# cp -a "$WORKDIR/webarena_data/mysql/." "$MYSQL_LOCAL/"
# echo "Copied MySQL data to $MYSQL_LOCAL ($(du -sh "$MYSQL_LOCAL" | cut -f1))"

# # Create a local /run equivalent to avoid NFS lock issues for PHP-FPM, nginx, etc.
# # /run bind-mounted from NFS causes "Cannot create lock - I/O error (5)" in PHP-FPM.
# RUN_LOCAL=/tmp/webarena_run_shopping_admin
# rm -rf "$RUN_LOCAL"
# mkdir -p "$RUN_LOCAL/mysqld" "$RUN_LOCAL/nginx" "$RUN_LOCAL/php-fpm" "$RUN_LOCAL/redis"
# chmod 777 "$RUN_LOCAL" "$RUN_LOCAL/mysqld" "$RUN_LOCAL/nginx" "$RUN_LOCAL/php-fpm" "$RUN_LOCAL/redis"
# # .init marks MySQL as already initialized so docker-entrypoint.sh skips mysql_install_db
# touch "$RUN_LOCAL/mysqld/.init"

# # Create a local /tmp for the container to avoid NFS lock issues.
# # PHP-FPM creates its accept lock in /tmp; NFS returns EIO (5) for fcntl() locks.
# TMP_LOCAL=/tmp/webarena_tmp_shopping_admin
# rm -rf "$TMP_LOCAL"
# mkdir -p "$TMP_LOCAL"
# chmod 1777 "$TMP_LOCAL"

# apptainer instance start \
#   --bind "$(pwd)/custom_configs/start.sh:/docker-entrypoint.sh" \
#   --bind "$(pwd)/custom_configs/supervisord.conf:/etc/supervisord.conf" \
#   --bind "$(pwd)/custom_configs/nginx.conf:/etc/nginx/nginx.conf" \
#   --bind "$(pwd)/custom_configs/conf_default.conf:/etc/nginx/conf.d/default.conf" \
#   --bind "$(pwd)/custom_configs/mysql.ini:/etc/supervisor.d/mysql.ini" \
#   --bind "$(pwd)/webarena_data/nginx:/var/lib/nginx" \
#   --bind "$MYSQL_LOCAL:/var/lib/mysql" \
#   --bind "$(pwd)/webarena_data/redis:/var/lib/redis" \
#   --bind "$TMP_LOCAL:/tmp" \
#   --bind "$(pwd)/webarena_data/log:/var/log" \
#   --bind "$RUN_LOCAL:/run" \
#   --bind "$ES_LOCAL:/usr/share/java/elasticsearch/data" \
#   --bind "$(pwd)/webarena_data/eslog:/usr/share/java/elasticsearch/logs" \
#   --bind "$(pwd)/webarena_data/es_config:/usr/share/java/elasticsearch/config" \
#   --bind "$(pwd)/webarena_data/magento_var:/var/www/magento2/var" \
#   --bind "$(pwd)/webarena_data/magento_generated:/var/www/magento2/generated" \
#   shopping_admin.sif webarena_shopping_admin

# # The SIF's %startscript is empty (Docker image had no startscript section).
# # We must launch supervisord explicitly after the instance namespace is up.
# echo "Instance started. Launching supervisord..."
# apptainer exec instance://webarena_shopping_admin \
#   supervisord -n -c /etc/supervisord.conf &
# sleep 2
# echo "Waiting for services to become ready..."

# # Wait for MySQL to accept connections
# echo "Waiting for MySQL..."
# for i in $(seq 1 60); do
#     if apptainer exec instance://webarena_shopping_admin \
#          mysql -h127.0.0.1 -umagentouser -pMyPassword -e "SELECT 1" magentodb &>/dev/null 2>&1; then
#         echo "MySQL ready."
#         break
#     fi
#     echo "  attempt $i/60, waiting 5s..."
#     sleep 5
# done

# # Update Magento base URL to actual node hostname so SOCKS5 proxy works
# NODE=$(hostname)
# echo "Updating Magento base URL to http://$NODE:7780/ ..."
# apptainer exec instance://webarena_shopping_admin \
#   mysql -h127.0.0.1 -umagentouser -pMyPassword magentodb -e \
#   "UPDATE core_config_data SET value='http://$NODE:7780/' WHERE path LIKE 'web/%base_url%';"

# echo "Flushing Magento cache..."
# apptainer exec instance://webarena_shopping_admin \
#   php /var/www/magento2/bin/magento cache:flush

# # Write node file only now — health check and BrowserGym will not attempt login until
# # this file appears, ensuring MySQL and cache are fully ready.
# echo "$NODE" > "$(dirname "$0")/../homepage/.shopping_admin_node"
# echo "Updated homepage/.shopping_admin_node → $NODE"

# echo "=== Shopping Admin ready at http://$NODE:7780 ==="
