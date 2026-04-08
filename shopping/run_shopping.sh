#!/bin/bash

cd /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/shopping/
DATA_DIR="${WEBARENA_DATA_DIR:-$(pwd)/webarena_data}"
INST="${INSTANCE_SUFFIX:-}"

# Stop any stale instance from a previous run. If the job was killed by SIGKILL,
# the SLURM trap never fired and the instance pid file remains in ~/.apptainer/instances/,
# causing the next `apptainer instance start` to fail with "instance already exists".
apptainer instance stop webarena_shopping 2>/dev/null || true

chmod -R 777 "$DATA_DIR"

# Ensure nginx tmp dirs exist
mkdir -p $(pwd)/webarena_data/nginx/tmp/client_body
mkdir -p $(pwd)/webarena_data/nginx/tmp/proxy
mkdir -p $(pwd)/webarena_data/nginx/tmp/fastcgi
mkdir -p $(pwd)/webarena_data/nginx/tmp/uwsgi
mkdir -p $(pwd)/webarena_data/nginx/tmp/scgi

# Re-extract nginx configs each run (port 80 → 7770)
apptainer exec shopping.sif cat /etc/nginx/conf.d/default.conf > $(pwd)/custom_configs/conf_default.conf
apptainer exec shopping.sif cat /etc/nginx/http.d/default.conf > $(pwd)/custom_configs/http_default.conf

sed -i 's/listen 80/listen 7770/g' $(pwd)/custom_configs/conf_default.conf
sed -i 's/listen \[::\]:80/listen \[::\]:7770/g' $(pwd)/custom_configs/conf_default.conf
sed -i 's/listen 80/listen 7770/g' $(pwd)/custom_configs/http_default.conf
sed -i 's/listen \[::\]:80/listen \[::\]:7770/g' $(pwd)/custom_configs/http_default.conf

# --- Stale file cleanup (SLURM kills leave these; they prevent clean restart) ---
# MariaDB: DDL recovery artifacts, temp files, PIDs, socket
# NOTE: do NOT delete ib_logfile0/1 — those are InnoDB redo logs needed for
# crash recovery after an unclean shutdown. Deleting them causes MySQL to fail
# to start when data files are dirty (502 on every restart).
rm -f $(pwd)/webarena_data/mysql/ibtmp1
rm -f $(pwd)/webarena_data/mysql/aria_log.00000001
rm -f $(pwd)/webarena_data/mysql/aria_log_control
rm -f $(pwd)/webarena_data/mysql/ddl_recovery.log
rm -f $(pwd)/webarena_data/mysql/ddl_recovery-backup.log
rm -f $(pwd)/webarena_data/mysql/*.pid
rm -f $(pwd)/webarena_data/run/mysqld/mysqld.sock
rm -f $(pwd)/webarena_data/run/mysqld/mysqld.pid
# Nginx, cron, supervisord PIDs and sockets
rm -f $(pwd)/webarena_data/run/nginx.pid
rm -f $(pwd)/webarena_data/run/crond.pid
rm -f $(pwd)/webarena_data/run/supervisord.sock
# NFS silly-rename files (created when files are deleted while still open)
find $(pwd)/webarena_data/run -name ".nfs*" -delete 2>/dev/null || true
# Elasticsearch: node lock and all write locks (prevents ES from starting after unclean kill)
rm -f $(pwd)/webarena_data/esdata/nodes/0/node.lock
find $(pwd)/webarena_data/esdata -name "write.lock" -delete 2>/dev/null || true
# Magento: cache regeneration lock
rm -f $(pwd)/webarena_data/magento_var/.regenerate.lock

# Copy ES data to local /tmp to avoid NFS file locking issues.
# NFS (scratch3) does not support fcntl() locks; Java's NativeFSLockFactory
# throws IOException instead of returning null, so ES crash-loops indefinitely.
# /tmp on the compute node is local storage — locking works there.
ES_LOCAL=/tmp/webarena_esdata_shopping
rm -rf "$ES_LOCAL"
cp -a $(pwd)/webarena_data/esdata/. "$ES_LOCAL/"
echo "Copied ES data to $ES_LOCAL ($(du -sh "$ES_LOCAL" | cut -f1))"

# Copy MySQL data if not already done
if [ ! -d "$(pwd)/webarena_data/mysql/mysql" ]; then
    echo "Initializing MySQL data from SIF..."
    apptainer exec shopping.sif cp -a /var/lib/mysql/. $(pwd)/webarena_data/mysql/
    chmod -R 777 $(pwd)/webarena_data/mysql
fi

# Ensure MySQL log directory exists (needed by custom mysql.ini)
mkdir -p $(pwd)/webarena_data/log/mysql

# Copy MySQL data to local /tmp to avoid NFS file locking issues.
# InnoDB uses fcntl() locks on ibdata1; NFS (scratch3) returns EIO (5) for these.
# /tmp on the compute node is local storage — locking works there.
MYSQL_LOCAL=/tmp/webarena_mysql_shopping
rm -rf "$MYSQL_LOCAL"
cp -a $(pwd)/webarena_data/mysql/. "$MYSQL_LOCAL/"
echo "Copied MySQL data to $MYSQL_LOCAL ($(du -sh "$MYSQL_LOCAL" | cut -f1))"

# Create a local /var/run equivalent to avoid NFS lock issues for PHP-FPM, nginx, etc.
# /var/run bind-mounted from NFS causes "Cannot create lock - I/O error (5)" in PHP-FPM.
RUN_LOCAL=/tmp/webarena_run_shopping
rm -rf "$RUN_LOCAL"
mkdir -p "$RUN_LOCAL/mysqld" "$RUN_LOCAL/nginx" "$RUN_LOCAL/php-fpm"
chmod 777 "$RUN_LOCAL" "$RUN_LOCAL/mysqld" "$RUN_LOCAL/nginx" "$RUN_LOCAL/php-fpm"
# .init marks MySQL as already initialized so docker-entrypoint.sh skips mysql_install_db
touch "$RUN_LOCAL/mysqld/.init"

# Create a local /tmp for the container to avoid NFS lock issues.
# PHP-FPM creates its accept lock in /tmp; NFS returns EIO (5) for fcntl() locks.
TMP_LOCAL=/tmp/webarena_tmp_shopping
rm -rf "$TMP_LOCAL"
mkdir -p "$TMP_LOCAL"
chmod 1777 "$TMP_LOCAL"

# Start the instance with all bind mounts
apptainer instance run \
  --bind $(pwd)/custom_configs/conf_default.conf:/etc/nginx/conf.d/default.conf \
  --bind $(pwd)/custom_configs/http_default.conf:/etc/nginx/http.d/default.conf \
  --bind $(pwd)/custom_configs/elasticsearch.ini:/etc/supervisor.d/elasticsearch.ini \
  --bind $(pwd)/custom_configs/mysql.ini:/etc/supervisor.d/mysql.ini \
  --bind $(pwd)/webarena_data/nginx:/var/lib/nginx \
  --bind $MYSQL_LOCAL:/var/lib/mysql \
  --bind $TMP_LOCAL:/tmp \
  --bind $(pwd)/webarena_data/log:/var/log \
  --bind $RUN_LOCAL:/var/run \
  --bind $ES_LOCAL:/usr/share/java/elasticsearch/data \
  --bind $(pwd)/webarena_data/eslog:/usr/share/java/elasticsearch/logs \
  --bind $(pwd)/webarena_data/magento_var:/var/www/magento2/var \
  --bind $(pwd)/webarena_data/magento_generated:/var/www/magento2/generated \
  --env "ES_JAVA_OPTS=-Xms512m -Xmx512m" \
  shopping.sif webarena_shopping

# Wait for MySQL to accept connections
echo "Waiting for MySQL..."
for i in $(seq 1 60); do
    if apptainer exec instance://webarena_shopping \
         mysql -h127.0.0.1 -umagentouser -pMyPassword -e "SELECT 1" magentodb &>/dev/null 2>&1; then
        echo "MySQL ready."
        break
    fi
    echo "  attempt $i/60, waiting 5s..."
    sleep 5
done

# Update Magento base URL to actual node hostname so SOCKS5 proxy works
NODE=$(hostname)
echo "Updating Magento base URL to http://$NODE:7770/ ..."
apptainer exec instance://webarena_shopping \
  mysql -h127.0.0.1 -umagentouser -pMyPassword magentodb -e \
  "UPDATE core_config_data SET value='http://$NODE:7770/' WHERE path LIKE 'web/%base_url%';"

echo "Flushing Magento cache..."
apptainer exec instance://webarena_shopping \
  php /var/www/magento2/bin/magento cache:flush

echo "=== Shopping ready at http://$NODE:7770 ==="