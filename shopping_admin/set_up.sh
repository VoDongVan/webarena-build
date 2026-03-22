#!/bin/bash
# =============================================================================
# set_up.sh — One-time setup for WebArena shopping_admin site on Unity HPC
# Run this ONCE from a compute node after salloc.
# After this completes, use run_shopping_admin.sh for all future starts.
# =============================================================================

set -e  # Exit immediately on any error

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"
echo "Working directory: $WORKDIR"

# =============================================================================
# STEP 1 — SIF check
# =============================================================================
echo ""
echo ">>> [1/7] Checking for Apptainer SIF..."

if [ ! -f shopping_admin.sif ]; then
    if [ ! -f shopping_admin_final_0719.tar ]; then
        echo "    ERROR: shopping_admin_final_0719.tar not found. Run download.sh first."
        exit 1
    fi
    echo "    Building SIF from tar archive (this may take 10-20 minutes)..."
    apptainer build shopping_admin.sif docker-archive:shopping_admin_final_0719.tar
else
    echo "    shopping_admin.sif already exists, skipping build."
fi

# =============================================================================
# STEP 2 — Create directory structure
# =============================================================================
echo ""
echo ">>> [2/7] Creating bind-mount directories..."

mkdir -p custom_configs
mkdir -p webarena_data/nginx/logs
mkdir -p webarena_data/mysql
mkdir -p webarena_data/redis
mkdir -p webarena_data/tmp
mkdir -p webarena_data/log
mkdir -p webarena_data/run
mkdir -p webarena_data/run/mysqld
mkdir -p webarena_data/esdata
mkdir -p webarena_data/eslog
mkdir -p webarena_data/es_config
mkdir -p webarena_data/magento_var
mkdir -p webarena_data/magento_generated

# =============================================================================
# STEP 3 — Extract data from SIF (idempotent)
# =============================================================================
echo ""
echo ">>> [3/7] Extracting writable data from SIF (skips if already done)..."

if [ ! -f "webarena_data/mysql/ibdata1" ]; then
    echo "    Extracting MySQL data..."
    apptainer exec shopping_admin.sif cp -a /var/lib/mysql/. webarena_data/mysql/
    chmod -R 777 webarena_data/mysql
else
    echo "    MySQL data already extracted, skipping."
fi

if [ -z "$(ls -A webarena_data/esdata/)" ]; then
    echo "    Extracting Elasticsearch data..."
    apptainer exec shopping_admin.sif cp -a /usr/share/java/elasticsearch/data/. webarena_data/esdata/
    chmod -R 777 webarena_data/esdata
else
    echo "    Elasticsearch data already extracted, skipping."
fi

if [ -z "$(ls -A webarena_data/eslog/)" ]; then
    echo "    Extracting Elasticsearch logs..."
    apptainer exec shopping_admin.sif cp -a /usr/share/java/elasticsearch/logs/. webarena_data/eslog/
    chmod -R 777 webarena_data/eslog
else
    echo "    Elasticsearch logs already extracted, skipping."
fi

if [ ! -f "webarena_data/es_config/elasticsearch.yml" ]; then
    echo "    Extracting and patching Elasticsearch config..."
    apptainer exec shopping_admin.sif cp -a /usr/share/java/elasticsearch/config/. webarena_data/es_config/
    chmod -R 777 webarena_data/es_config
    cat >> webarena_data/es_config/elasticsearch.yml << 'EOF'

# Apptainer overrides
discovery.type: single-node
path.data: /usr/share/java/elasticsearch/data
path.logs: /usr/share/java/elasticsearch/logs
EOF
else
    echo "    Elasticsearch config already extracted, skipping."
fi

if [ -z "$(ls -A webarena_data/magento_var/)" ]; then
    echo "    Extracting Magento var directory..."
    apptainer exec shopping_admin.sif cp -a /var/www/magento2/var/. webarena_data/magento_var/
    chmod -R 777 webarena_data/magento_var
else
    echo "    Magento var already extracted, skipping."
fi

if [ -z "$(ls -A webarena_data/magento_generated/)" ]; then
    echo "    Extracting Magento generated code..."
    apptainer exec shopping_admin.sif cp -a /var/www/magento2/generated/. webarena_data/magento_generated/
    chmod -R 777 webarena_data/magento_generated
else
    echo "    Magento generated already extracted, skipping."
fi

if [ ! -f "webarena_data/redis/dump.rdb" ]; then
    echo "    Extracting Redis data..."
    apptainer exec shopping_admin.sif cp -a /var/lib/redis/. webarena_data/redis/
    chmod -R 777 webarena_data/redis
else
    echo "    Redis data already extracted, skipping."
fi

# =============================================================================
# STEP 4 — Create custom config files
# =============================================================================
echo ""
echo ">>> [4/7] Creating custom config files..."

echo "    Patching nginx vhost config (port 80 → 7780)..."
apptainer exec shopping_admin.sif cat /etc/nginx/conf.d/default.conf > custom_configs/conf_default.conf
sed -i 's/listen 80/listen 7780/g' custom_configs/conf_default.conf
sed -i 's/listen \[::\]:80/listen \[::\]:7780/g' custom_configs/conf_default.conf

echo "    Writing nginx.conf..."
cat > custom_configs/nginx.conf << 'EOF'
user  nginx;
daemon  off;
worker_processes  10;

error_log  /var/log/nginx/error.log warn;
pid  /var/run/nginx.pid;

events {
  worker_connections  1024;
}

http {
  include  /etc/nginx/mime.types;
  default_type  application/octet-stream;

  log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
    '$status $body_bytes_sent "$http_referer" '
    '"$http_user_agent" "$http_x_forwarded_for"';

  access_log  /var/log/nginx/access.log  main;

  sendfile  on;
  tcp_nopush  on;

  keepalive_timeout  65;

  include /etc/nginx/conf.d/*.conf;
}
EOF

echo "    Writing supervisord.conf..."
cat > custom_configs/supervisord.conf << 'EOF'
[unix_http_server]
file=/run/supervisord.sock

[supervisord]
logfile=/var/log/supervisord.log
nodaemon=true

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///run/supervisord.sock

[program:mysqld]
command=mysqld --datadir=/var/lib/mysql --socket=/run/mysqld/mysqld.sock --pid-file=/run/mysqld/mysqld.pid --bind-address=127.0.0.1 --log-error=/var/log/mysql.err
autostart=true
autorestart=true
priority=1
startretries=3
stopwaitsecs=30
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:redis-server]
command=redis-server /etc/redis.conf --logfile ""
autostart=true
autorestart=true
priority=2
startretries=3
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:php-fpm]
command=php-fpm --nodaemonize --fpm-config /usr/local/etc/php-fpm.conf
autostart=true
autorestart=true
priority=3
startretries=3
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:elasticsearch]
command=/usr/share/java/elasticsearch/bin/elasticsearch
environment=ES_JAVA_HOME=/usr,ES_PATH_CONF=/usr/share/java/elasticsearch/config,ES_JAVA_OPTS="-Xms512m -Xmx512m"
autostart=true
autorestart=true
priority=4
startretries=3
stopwaitsecs=30
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:nginx]
command=nginx -c /etc/nginx/nginx.conf
autostart=true
autorestart=true
priority=5
startretries=3
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:cron]
command=crond -f
autostart=true
autorestart=true
priority=6
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

# =============================================================================
# STEP 5 — Generate run_shopping_admin.sh
# =============================================================================
echo ""
echo ">>> [5/7] Generating run_shopping_admin.sh..."

cat > run_shopping_admin.sh << 'RUNEOF'
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

apptainer instance start \
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
  shopping_admin.sif webarena_shopping_admin \
  supervisord -n -c /etc/supervisord.conf

echo "Instance started. Waiting for services..."
RUNEOF

chmod +x run_shopping_admin.sh

# =============================================================================
# STEP 6 — First boot
# =============================================================================
echo ""
echo ">>> [6/7] Starting instance for the first time..."

sh run_shopping_admin.sh

echo "    Waiting for all services to become ready..."
for i in $(seq 1 30); do
    CODE=$(apptainer exec instance://webarena_shopping_admin \
        curl -s -o /dev/null -w "%{http_code}" http://localhost:7780 2>/dev/null || echo "000")
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
        echo "    Services ready (HTTP $CODE)."
        break
    fi
    echo "    Attempt $i/30: HTTP $CODE, waiting 5s..."
    sleep 5
done

# =============================================================================
# STEP 7 — Post-boot configuration (URL fix + reindex)
# =============================================================================
echo ""
echo ">>> [7/7] Running first-boot configuration..."

echo "    Updating Magento base URL to http://localhost:7780/ ..."
apptainer exec instance://webarena_shopping_admin \
    mysql -u root --socket=/run/mysqld/mysqld.sock magento -e "
        UPDATE core_config_data SET value='http://localhost:7780/' WHERE path='web/unsecure/base_url';
        UPDATE core_config_data SET value='http://localhost:7780/' WHERE path='web/secure/base_url';
        FLUSH TABLES;
    "

echo "    Flushing Magento cache..."
apptainer exec instance://webarena_shopping_admin \
    php /var/www/magento2/bin/magento cache:flush

echo "    Reindexing (this will take a few minutes)..."
apptainer exec instance://webarena_shopping_admin \
    php /var/www/magento2/bin/magento indexer:reindex 2>&1

echo "    Flushing cache again after reindex..."
apptainer exec instance://webarena_shopping_admin \
    php /var/www/magento2/bin/magento cache:flush

# =============================================================================
# Done
# =============================================================================
echo ""
echo "============================================================"
echo " Setup complete!"
echo " The shopping_admin site is running at http://localhost:7780"
echo " (inside the cluster)"
echo ""
echo " To access from your laptop, run this SSH tunnel command:"
echo "   ssh -L 7780:$(hostname):7780 <username>@unity.rc.umass.edu"
echo " Then open http://localhost:7780 in your browser."
echo ""
echo " To stop the instance:  apptainer instance stop webarena_shopping_admin"
echo " To restart next time:  sh run_shopping_admin.sh"
echo "============================================================"
