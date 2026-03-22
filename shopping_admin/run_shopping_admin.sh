#!/bin/bash

BASE=/scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/shopping_admin
DATA=$BASE/webarena_data

cd $BASE

echo "=== Shopping Admin starting on $(hostname) at $(date) ==="
echo "=== SSH tunnel: ssh -L 7780:$(hostname):7780 unity ==="

# ── 1. Create all writable directories ───────────────────────────────────────
mkdir -p \
    $DATA/log \
    $DATA/log/redis \
    $DATA/log/nginx \
    $DATA/mysql \
    $DATA/run/mysqld\
    $DATA/redis \
    $DATA/es_data \
    $DATA/es_logs \
    $DATA/es_config \
    $DATA/es_cache/JNA/temp \
    $DATA/run/mysqld \
    $DATA/run/nginx \
    $DATA/run/php \
    $DATA/magento_var \
    $DATA/tmp \
    $DATA/run/redis

chmod -R 777 $DATA

# ── 2. Extract MySQL data (once) ─────────────────────────────────────────────
if [ ! -f "$DATA/mysql/ibdata1" ]; then
    echo "[$(date)] Extracting MySQL data from SIF (this may take a minute)..."
    apptainer exec $BASE/shopping_admin.sif cp -a /var/lib/mysql/. $DATA/mysql/
    chmod -R 777 $DATA/mysql
    echo "[$(date)] MySQL extraction done."
fi

# ── 3. Extract and patch Elasticsearch config (once) ─────────────────────────
if [ ! -f "$DATA/es_config/elasticsearch.yml" ]; then
    echo "[$(date)] Extracting Elasticsearch config from SIF..."
    apptainer exec $BASE/shopping_admin.sif cp -a /usr/share/java/elasticsearch/config/. $DATA/es_config/
    chmod -R 777 $DATA/es_config
    cat >> $DATA/es_config/elasticsearch.yml <<'EOF'

# Apptainer overrides
discovery.type: single-node
path.data: /usr/share/java/elasticsearch/data
path.logs: /usr/share/java/elasticsearch/logs
EOF
    echo "[$(date)] Elasticsearch config extracted and patched."
fi

# ── 4. Write custom nginx vhost (port 7780 instead of 80) ────────────────────
cat > $DATA/nginx_vhost.conf <<'EOF'
upstream fastcgi_backend {
  server  127.0.0.1:9000;
}

server {
  listen 7780;
  listen [::]:7780 ipv6only=on default_server;
  server_name _;
  set $MAGE_ROOT /var/www/magento2;
  include /var/www/magento2/nginx.conf.sample;
}
EOF

#───────────────────── Write patched nginx.conf with explicit log paths ─────────────────────
#error_log  /var/log/nginx_error.log warn;
cat > $DATA/nginx.conf <<'EOF'
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

# ── 5. Write custom supervisord.conf ─────────────────────────────────────────
# Changes from original:
#   - mysqld: removed --user=mysql
#   - elasticsearch: replaced `su elastico -c` with direct invocation
#   - mailcatcher: removed (port 25 blocked on HPC)
cat > $DATA/supervisord.conf <<'EOF'
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

# ── 6. Launch container in background, patch URLs, then wait ─────────────────
echo "[$(date)] Launching Apptainer..."
apptainer exec \
    --bind $DATA/mysql:/var/lib/mysql \
    --bind $DATA/redis:/var/lib/redis \
    --bind $DATA/es_data:/usr/share/java/elasticsearch/data \
    --bind $DATA/es_logs:/usr/share/java/elasticsearch/logs \
    --bind $DATA/es_config:/usr/share/java/elasticsearch/config \
    --bind $DATA/es_cache:/usr/share/java/elasticsearch/.cache \
    --bind $DATA/run:/run \
    --bind $DATA/log:/var/log \
    --bind $DATA/log/nginx:/var/lib/nginx/logs \
    --bind $DATA/magento_var:/var/www/magento2/var \
    --bind $DATA/supervisord.conf:/etc/supervisord.conf \
    --bind $DATA/nginx_vhost.conf:/etc/nginx/conf.d/default.conf \
    --bind $DATA/nginx.conf:/etc/nginx/nginx.conf \
    --bind $DATA/tmp:/tmp \
    $BASE/shopping_admin.sif \
    supervisord -n -c /etc/supervisord.conf &

SUPERVISORD_PID=$!

# ── 7. Wait for MySQL to be ready ────────────────────────────────────────────
echo "[$(date)] Waiting for MySQL to be ready..."
for i in $(seq 1 30); do
    if apptainer exec \
        --bind $DATA/mysql:/var/lib/mysql \
        --bind $DATA/run:/run \
        $BASE/shopping_admin.sif \
        mysqladmin ping --socket=/run/mysqld/mysqld.sock --silent 2>/dev/null; then
        echo "[$(date)] MySQL is up."
        break
    fi
    echo "[$(date)] MySQL not ready yet, waiting... ($i/30)"
    sleep 2
done

# ── 8. Patch Magento base URLs ────────────────────────────────────────────────
echo "[$(date)] Patching Magento base URLs..."
apptainer exec \
    --bind $DATA/mysql:/var/lib/mysql \
    --bind $DATA/run:/run \
    $BASE/shopping_admin.sif \
    mysql -u root --socket=/run/mysqld/mysqld.sock -e "
        USE magento;
        UPDATE core_config_data SET value='http://localhost:7780/' WHERE path='web/unsecure/base_url';
        UPDATE core_config_data SET value='http://localhost:7780/' WHERE path='web/secure/base_url';
        FLUSH TABLES;
    "
echo "[$(date)] Base URLs patched."

# ── 9. Flush Magento cache ────────────────────────────────────────────────────
echo "[$(date)] Flushing Magento cache..."
apptainer exec \
    --bind $DATA/magento_var:/var/www/magento2/var \
    --bind $DATA/tmp:/tmp \
    $BASE/shopping_admin.sif \
    php /var/www/magento2/bin/magento cache:flush
echo "[$(date)] Cache flushed."

# ── 10. Keep script alive until supervisord exits ─────────────────────────────
wait $SUPERVISORD_PID