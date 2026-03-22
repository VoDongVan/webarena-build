#!/bin/bash

cd /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/shopping/
chmod -R 777 /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/shopping/webarena_data

# Re-extract nginx configs each run (port 80 → 8080)
apptainer exec shopping.sif cat /etc/nginx/conf.d/default.conf > $(pwd)/custom_configs/conf_default.conf
apptainer exec shopping.sif cat /etc/nginx/http.d/default.conf > $(pwd)/custom_configs/http_default.conf

sed -i 's/listen 80/listen 8080/g' $(pwd)/custom_configs/conf_default.conf
sed -i 's/listen \[::\]:80/listen \[::\]:8080/g' $(pwd)/custom_configs/conf_default.conf
sed -i 's/listen 80/listen 8080/g' $(pwd)/custom_configs/http_default.conf
sed -i 's/listen \[::\]:80/listen \[::\]:8080/g' $(pwd)/custom_configs/http_default.conf

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