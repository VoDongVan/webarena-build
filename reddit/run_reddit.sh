#!/bin/bash
# run_reddit.sh — Start a fresh WebArena Reddit (Postmill) instance.

# --- Configuration ---
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"
SIF_FILE="reddit.sif"
INSTANCE_NAME="webarena_reddit"
PORT=9999

# Local workspace on the node's SSD (196GB available on /tmp)
WORKSPACE="/tmp/webarena_runtime_reddit"
NODE=$(hostname)

# --- Cleanup Function ---
cleanup() {
    echo "Stopping instance and cleaning up local workspace..."
    apptainer instance stop $INSTANCE_NAME 2>/dev/null || true
    rm -rf "$WORKSPACE"
    exit
}
trap cleanup EXIT SIGTERM

echo "=== Reddit (Postmill) starting on $NODE at $(date) ==="

# --- 1. Fresh Start: Environment Prep ---
apptainer instance stop $INSTANCE_NAME 2>/dev/null || true

echo "Wiping and recreating local workspace in $WORKSPACE..."
rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE/pgsql" "$WORKSPACE/run/postgresql" "$WORKSPACE/run/nginx" \
         "$WORKSPACE/log/nginx" "$WORKSPACE/postmill_var" \
         "$(pwd)/custom_configs"

# IMPORTANT: PostgreSQL requires strict 700 permissions on its data dir
chmod 700 "$WORKSPACE/pgsql"
# Everything else can be broader
chmod 777 "$WORKSPACE/run" "$WORKSPACE/log" "$WORKSPACE/postmill_var"

# --- 2. Force Extraction from SIF (Gold Source) ---
echo "Extracting pristine data from $SIF_FILE..."

# PostgreSQL Data
apptainer exec $SIF_FILE cp -a /usr/local/pgsql/data/. "$WORKSPACE/pgsql/"
# Reddit (Symfony/Postmill) Var (Cache/Logs)
apptainer exec $SIF_FILE cp -a /var/www/html/var/. "$WORKSPACE/postmill_var/" 2>/dev/null || true

# Ensure permissions are correct after copy
chmod 700 "$WORKSPACE/pgsql"
rm -rf "$WORKSPACE/postmill_var/cache/"* # Ensure fresh Symfony cache

# --- 3. Configuration & Entrypoint Setup ---
echo "Patching configurations for port $PORT..."

# Patch Nginx vhost
apptainer exec $SIF_FILE cat /etc/nginx/conf.d/default.conf > "$WORKDIR/custom_configs/conf_default.conf"
sed -i "s/listen 80/listen $PORT/g" "$WORKDIR/custom_configs/conf_default.conf"
sed -i "s/listen \[::\]:80/listen \[::\]:$PORT/g" "$WORKDIR/custom_configs/conf_default.conf"

# Patch Nginx main config for SSD temp paths
apptainer exec $SIF_FILE cat /etc/nginx/nginx.conf > "$WORKDIR/custom_configs/nginx.conf"
sed -i '/http {/a\  client_body_temp_path /run/nginx/client_body;\n  proxy_temp_path /run/nginx/proxy;\n  fastcgi_temp_path /run/nginx/fastcgi;\n  uwsgi_temp_path /run/nginx/uwsgi;\n  scgi_temp_path /run/nginx/scgi;' \
    "$WORKDIR/custom_configs/nginx.conf"
mkdir -p "$WORKSPACE/run/nginx/client_body" "$WORKSPACE/run/nginx/proxy" "$WORKSPACE/run/nginx/fastcgi" "$WORKSPACE/run/nginx/uwsgi" "$WORKSPACE/run/nginx/scgi"

# Create the startup bypass script
cat > "$WORKDIR/custom_configs/start.sh" << 'EOF'
#!/bin/sh
exec supervisord -n -j /supervisord.pid -c /etc/supervisord.conf
EOF
chmod +x "$WORKDIR/custom_configs/start.sh"

# --- 4. Start the Fresh Instance ---
echo "Starting Apptainer instance..."

apptainer instance start \
  --bind "$WORKDIR/custom_configs/start.sh:/docker-entrypoint.sh" \
  --bind "$WORKDIR/custom_configs/pgsql.ini:/etc/supervisor.d/pgsql.ini" \
  --bind "$WORKDIR/custom_configs/nginx.conf:/etc/nginx/nginx.conf" \
  --bind "$WORKDIR/custom_configs/conf_default.conf:/etc/nginx/conf.d/default.conf" \
  --bind "$WORKSPACE/pgsql:/usr/local/pgsql/data" \
  --bind "$WORKSPACE/run:/run" \
  --bind "$WORKSPACE/run:/var/run" \
  --bind "$WORKSPACE/log:/var/log" \
  --bind "$WORKSPACE/postmill_var:/var/www/html/var" \
  $SIF_FILE $INSTANCE_NAME

echo "Launching supervisord..."
apptainer exec instance://$INSTANCE_NAME /docker-entrypoint.sh &

# --- 5. Service Readiness ---
echo "Waiting for Reddit on http://$NODE:$PORT ..."
for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$PORT 2>/dev/null || echo "000")
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
        echo "Reddit is ready (HTTP $CODE)."
        break
    fi
    [ $i -eq 30 ] && echo "Reddit failed to start." && exit 1
    echo "  Attempt $i/30: HTTP $CODE, waiting 5s..."
    sleep 5
done

# Update service discovery for the homepage (consistent with other scripts)
echo "$NODE" > "$WORKDIR/../homepage/.reddit_node"

echo "=== Reddit Freshly Deployed ==="
echo "URL: http://$NODE:$PORT"
echo "SSH tunnel: ssh -L $PORT:$NODE:$PORT <username>@unity.rc.umass.edu"

# Keep the script running so the trap doesn't trigger immediately
# If running via SLURM, this will keep the allocation alive
sleep infinity & wait $!