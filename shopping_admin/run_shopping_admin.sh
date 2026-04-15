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
# Magento var (caches, sessions)
apptainer exec $SIF_FILE cp -a /var/www/magento2/var/. "$WORKSPACE/magento_var/" 2>/dev/null || true
# Magento generated (DI interceptors, factories — pre-compiled so PHP skips on-demand codegen)
apptainer exec $SIF_FILE cp -a /var/www/magento2/generated/. "$WORKSPACE/magento_generated/" 2>/dev/null || true
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

echo "Waiting for Magento storefront HTTP readiness..."
for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://$NODE:$PORT/" || echo 000)
    if [[ "${code:0:1}" == "2" ]]; then
        echo "Magento storefront ready (code=$code)"
        break
    fi
    echo "Waiting... (HTTP $code)"
    sleep 5
    if [[ $i -eq 60 ]]; then
        echo "Magento HTTP readiness timeout"
        exit 1
    fi
done

# Warm up the admin panel before advertising readiness.
# The storefront (/) returns 200 quickly, but /admin triggers PHP code generation
# on first hit if magento_generated/ was empty. That compilation can take several
# minutes; Playwright times out (Locator.fill) waiting for the login form to appear.
# Hitting /admin here lets compilation finish before the agent's browser arrives.
echo "Warming up Magento admin panel (first hit triggers any remaining codegen)..."
for i in $(seq 1 120); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 "http://$NODE:$PORT/admin/" || echo 000)
    if [[ "${code:0:1}" == "2" || "${code:0:1}" == "3" ]]; then
        echo "Admin panel ready (HTTP $code)"
        break
    fi
    echo "  admin warmup [${i}×5s=${i*5}s elapsed] HTTP $code"
    sleep 5
    if [[ $i -eq 120 ]]; then
        echo "Admin panel warmup timeout (10 min) — proceeding anyway"
    fi
done

# Finalize readiness for service discovery — written only after both storefront
# AND admin are confirmed responsive, so the agent never races ahead.
echo "$NODE" > "$WORKDIR/../homepage/.shopping_admin_node"

echo "=== Shopping Admin Freshly Deployed ==="
echo "URL: http://$NODE:$PORT"
echo "SSH tunnel: ssh -L $PORT:$NODE:$PORT <username>@unity.rc.umass.edu"

# Keep the script running so the trap doesn't trigger immediately
# If running via SLURM, this will keep the allocation alive
sleep infinity & wait $!