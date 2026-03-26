#!/bin/bash

cd /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/shopping/
chmod -R 777 /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/shopping/webarena_data

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

# Copy MySQL data if not already done
if [ ! -d "$(pwd)/webarena_data/mysql/mysql" ]; then
    echo "Initializing MySQL data from SIF..."
    apptainer exec shopping.sif cp -a /var/lib/mysql/. $(pwd)/webarena_data/mysql/
    chmod -R 777 $(pwd)/webarena_data/mysql
fi

# Start the instance with all bind mounts
apptainer instance run \
  --bind $(pwd)/custom_configs/conf_default.conf:/etc/nginx/conf.d/default.conf \
  --bind $(pwd)/custom_configs/http_default.conf:/etc/nginx/http.d/default.conf \
  --bind $(pwd)/custom_configs/elasticsearch.ini:/etc/supervisor.d/elasticsearch.ini \
  --bind $(pwd)/webarena_data/nginx:/var/lib/nginx \
  --bind $(pwd)/webarena_data/mysql:/var/lib/mysql \
  --bind $(pwd)/webarena_data/tmp:/tmp \
  --bind $(pwd)/webarena_data/log:/var/log \
  --bind $(pwd)/webarena_data/run:/var/run \
  --bind $(pwd)/webarena_data/esdata:/usr/share/java/elasticsearch/data \
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