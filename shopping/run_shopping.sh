#!/bin/bash

# --- Configuration ---
cd /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/shopping/
SIF_FILE="shopping.sif"
INSTANCE_NAME="webarena_shopping"
PORT=7770

# Use a local workspace on the node's SSD to ensure freshness and avoid NFS lock issues
WORKSPACE="/tmp/webarena_runtime_shopping"
NODE=$(hostname)

# --- Cleanup Function ---
# This runs when the script finishes or is killed (SLURM cancel)
cleanup() {
    echo "Stopping instance and cleaning up local workspace..."
    apptainer instance stop $INSTANCE_NAME 2>/dev/null || true
    rm -rf "$WORKSPACE"
    exit
}
trap cleanup EXIT SIGTERM

# --- 1. Fresh Start: Environment Prep ---
echo "Initializing fresh environment in $WORKSPACE..."

# Stop any stale instances first
apptainer instance stop $INSTANCE_NAME 2>/dev/null || true

# Completely wipe and recreate the local workspace
rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE/mysql" "$WORKSPACE/esdata" "$WORKSPACE/eslog" "$WORKSPACE/run/mysqld" \
         "$WORKSPACE/run/nginx" "$WORKSPACE/run/php-fpm" "$WORKSPACE/tmp" \
         "$WORKSPACE/log/mysql" "$WORKSPACE/log/nginx" \
         "$WORKSPACE/magento_var" "$WORKSPACE/magento_generated" \
         "$WORKSPACE/nginx_tmp/tmp/client_body" \
         "$WORKSPACE/nginx_tmp/tmp/proxy" \
         "$WORKSPACE/nginx_tmp/tmp/fastcgi" \
         "$WORKSPACE/nginx_tmp/tmp/uwsgi" \
         "$WORKSPACE/nginx_tmp/tmp/scgi" \
         "$WORKSPACE/nginx_tmp/logs" \
         "$(pwd)/custom_configs"

chmod -R 777 "$WORKSPACE"
# .init tells the container's entrypoint that MySQL is already "installed"
touch "$WORKSPACE/run/mysqld/.init"

# --- 2. Force Extraction from SIF (The "Gold" Source) ---
echo "Extracting fresh state from $SIF_FILE..."

# MySQL Data
apptainer exec $SIF_FILE cp -a /var/lib/mysql/. "$WORKSPACE/mysql/"
# Elasticsearch Data
apptainer exec $SIF_FILE cp -a /usr/share/java/elasticsearch/data/. "$WORKSPACE/esdata/" 2>/dev/null || true
# Magento State
apptainer exec $SIF_FILE cp -a /var/www/magento2/var/. "$WORKSPACE/magento_var/" 2>/dev/null || true

# --- 3. Configuration Setup ---
echo "Generating custom configs for port $PORT..."

# Re-extract and modify nginx configs for the custom port
apptainer exec $SIF_FILE cat /etc/nginx/conf.d/default.conf > $(pwd)/custom_configs/conf_default.conf
apptainer exec $SIF_FILE cat /etc/nginx/http.d/default.conf > $(pwd)/custom_configs/http_default.conf

sed -i "s/listen 80/listen $PORT/g" $(pwd)/custom_configs/conf_default.conf
sed -i "s/listen \[::\]:80/listen \[::\]:7770/g" $(pwd)/custom_configs/conf_default.conf
sed -i "s/listen 80/listen $PORT/g" $(pwd)/custom_configs/http_default.conf
sed -i "s/listen \[::\]:80/listen \[::\]:7770/g" $(pwd)/custom_configs/http_default.conf

# --- 4. Start the Fresh Instance ---
echo "Starting Apptainer instance..."

apptainer instance run \
  --bind $(pwd)/custom_configs/conf_default.conf:/etc/nginx/conf.d/default.conf \
  --bind $(pwd)/custom_configs/http_default.conf:/etc/nginx/http.d/default.conf \
  --bind $(pwd)/custom_configs/elasticsearch.ini:/etc/supervisor.d/elasticsearch.ini \
  --bind $(pwd)/custom_configs/mysql.ini:/etc/supervisor.d/mysql.ini \
  --bind "$WORKSPACE/mysql:/var/lib/mysql" \
  --bind "$WORKSPACE/esdata:/usr/share/java/elasticsearch/data" \
  --bind "$WORKSPACE/eslog:/usr/share/java/elasticsearch/logs" \
  --bind "$WORKSPACE/run:/var/run" \
  --bind "$WORKSPACE/tmp:/tmp" \
  --bind "$WORKSPACE/log:/var/log" \
  --bind "$WORKSPACE/nginx_tmp:/var/lib/nginx" \
  --bind "$WORKSPACE/magento_var:/var/www/magento2/var" \
  --bind "$WORKSPACE/magento_generated:/var/www/magento2/generated" \
  --env "ES_JAVA_OPTS=-Xms512m -Xmx512m" \
  $SIF_FILE $INSTANCE_NAME

# --- 5. Service Readiness & Post-Setup ---
echo "Waiting for MySQL to accept connections on $NODE..."
for i in $(seq 1 60); do
    if apptainer exec instance://$INSTANCE_NAME \
         mysql -h127.0.0.1 -umagentouser -pMyPassword -e "SELECT 1" magentodb &>/dev/null 2>&1; then
        echo "MySQL is ready."
        break
    fi
    [ $i -eq 60 ] && echo "MySQL failed to start." && exit 1
    sleep 5
done

echo "Updating Magento base URL to http://$NODE:$PORT/ ..."
apptainer exec instance://$INSTANCE_NAME \
  mysql -h127.0.0.1 -umagentouser -pMyPassword magentodb -e \
  "UPDATE core_config_data SET value='http://$NODE:$PORT/' WHERE path LIKE 'web/%base_url%';"

echo "Flushing Magento cache..."
apptainer exec instance://$INSTANCE_NAME \
  php /var/www/magento2/bin/magento cache:flush

# Update service discovery for the homepage
echo "$NODE" > "$(pwd)/../homepage/.shopping_node"

echo "=== Shopping Site Freshly Deployed ==="
echo "URL: http://$NODE:$PORT"
echo "Workspace: $WORKSPACE"

# Keep the script running so the trap doesn't trigger immediately
# If running via SLURM, this will keep the allocation alive
sleep infinity & wait $!