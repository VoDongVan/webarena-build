#!/bin/bash
# run_shopping_admin.sh — Start the WebArena shopping_admin instance.
# Run this every time you want to start the site after set_up.sh has been run once.

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"

echo "=== Shopping Admin starting on $(hostname) at $(date) ==="
echo "=== SSH tunnel: ssh -L 7780:$(hostname):7780 <username>@unity.rc.umass.edu ==="

chmod -R 777 "$WORKDIR/webarena_data"

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

apptainer instance start \
  --bind "$(pwd)/custom_configs/start.sh:/docker-entrypoint.sh" \
  --bind "$(pwd)/custom_configs/supervisord.conf:/etc/supervisord.conf" \
  --bind "$(pwd)/custom_configs/nginx.conf:/etc/nginx/nginx.conf" \
  --bind "$(pwd)/custom_configs/conf_default.conf:/etc/nginx/conf.d/default.conf" \
  --bind "$(pwd)/webarena_data/nginx:/var/lib/nginx" \
  --bind "$(pwd)/webarena_data/mysql:/var/lib/mysql" \
  --bind "$(pwd)/webarena_data/redis:/var/lib/redis" \
  --bind "$(pwd)/webarena_data/tmp:/tmp" \
  --bind "$(pwd)/webarena_data/log:/var/log" \
  --bind "$(pwd)/webarena_data/run:/run" \
  --bind "$(pwd)/webarena_data/esdata:/usr/share/java/elasticsearch/data" \
  --bind "$(pwd)/webarena_data/eslog:/usr/share/java/elasticsearch/logs" \
  --bind "$(pwd)/webarena_data/es_config:/usr/share/java/elasticsearch/config" \
  --bind "$(pwd)/webarena_data/magento_var:/var/www/magento2/var" \
  --bind "$(pwd)/webarena_data/magento_generated:/var/www/magento2/generated" \
  shopping_admin.sif webarena_shopping_admin

echo "Instance started. Waiting for services..."
