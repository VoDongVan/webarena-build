#!/bin/bash
# =============================================================================
# setup.sh — One-time setup for WebArena shopping site on Unity HPC
# Run this ONCE from a compute node after salloc.
# After this completes, use run_shopping.sh for all future starts.
# =============================================================================
 
set -e  # Exit immediately on any error
 
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"
echo "Working directory: $WORKDIR"
 
# =============================================================================
# STEP 1 — Download and build the SIF
# =============================================================================
echo ""
echo ">>> [1/7] Building Apptainer SIF from Docker tar archive..."
 
if [ ! -f shopping.sif ]; then
    if [ ! -f shopping_final_0712.tar ]; then
        echo "    Downloading shopping_final_0712.tar from CMU..."
        wget http://metis.lti.cs.cmu.edu/webarena-images/shopping_final_0712.tar
    else
        echo "    Found existing shopping_final_0712.tar, skipping download."
    fi
    apptainer build shopping.sif docker-archive://shopping_final_0712.tar
    echo "    Removing tar file to save disk space..."
    rm -f shopping_final_0712.tar
else
    echo "    shopping.sif already exists, skipping build."
fi
 
# =============================================================================
# STEP 2 — Create directory structure
# =============================================================================
echo ""
echo ">>> [2/7] Creating bind-mount directories..."
 
mkdir -p custom_configs
mkdir -p webarena_data/nginx/logs
mkdir -p webarena_data/mysql
mkdir -p webarena_data/tmp
mkdir -p webarena_data/log
mkdir -p webarena_data/run
mkdir -p webarena_data/esdata
mkdir -p webarena_data/eslog
mkdir -p webarena_data/magento_var
mkdir -p webarena_data/magento_generated
 
# =============================================================================
# STEP 3 — Extract data from SIF
# =============================================================================
echo ""
echo ">>> [3/7] Extracting writable data from SIF (this may take a few minutes)..."
 
echo "    Extracting MySQL data..."
apptainer exec shopping.sif cp -a /var/lib/mysql/. webarena_data/mysql/
chmod -R 777 webarena_data/mysql
 
echo "    Extracting Elasticsearch data..."
apptainer exec shopping.sif cp -a /usr/share/java/elasticsearch/data/. webarena_data/esdata/
chmod -R 777 webarena_data/esdata
 
echo "    Extracting Elasticsearch logs..."
apptainer exec shopping.sif cp -a /usr/share/java/elasticsearch/logs/. webarena_data/eslog/
chmod -R 777 webarena_data/eslog
 
echo "    Extracting Magento var directory..."
apptainer exec shopping.sif cp -a /var/www/magento2/var/. webarena_data/magento_var/
chmod -R 777 webarena_data/magento_var
 
echo "    Extracting Magento generated code..."
apptainer exec shopping.sif cp -a /var/www/magento2/generated/. webarena_data/magento_generated/
chmod -R 777 webarena_data/magento_generated
 
# =============================================================================
# STEP 4 — Create custom config files
# =============================================================================
echo ""
echo ">>> [4/7] Creating custom config files..."
 
echo "    Patching nginx config (port 80 → 8080)..."
apptainer exec shopping.sif cat /etc/nginx/conf.d/default.conf > custom_configs/conf_default.conf
apptainer exec shopping.sif cat /etc/nginx/http.d/default.conf > custom_configs/http_default.conf
 
sed -i 's/listen 80/listen 8080/g' custom_configs/conf_default.conf
sed -i 's/listen \[::\]:80/listen \[::\]:8080/g' custom_configs/conf_default.conf
sed -i 's/listen 80/listen 8080/g' custom_configs/http_default.conf
sed -i 's/listen \[::\]:80/listen \[::\]:8080/g' custom_configs/http_default.conf
 
echo "    Creating rootless Elasticsearch supervisor config..."
cat > custom_configs/elasticsearch.ini << 'EOF'
[program:elasticsearch]
command=bash -c "ES_JAVA_HOME=/usr elasticsearch"
autostart=true
autorestart=true
priority=8
startretries=3
stopwaitsecs=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF
 
# =============================================================================
# STEP 5 — Create run_shopping.sh for future use
# =============================================================================
echo ""
echo ">>> [5/7] Creating run_shopping.sh for future use..."
 
cat > run_shopping.sh << RUNEOF
#!/bin/bash
# run_shopping.sh — Start the WebArena shopping instance.
# Run this every time you want to start the site after setup.sh has been run once.
 
WORKDIR="\$(cd "\$(dirname "\$0")" && pwd)"
cd "\$WORKDIR"
 
chmod -R 777 "\$WORKDIR/webarena_data"
 
# Re-extract nginx configs each run in case the node changed
apptainer exec shopping.sif cat /etc/nginx/conf.d/default.conf > "\$(pwd)/custom_configs/conf_default.conf"
apptainer exec shopping.sif cat /etc/nginx/http.d/default.conf > "\$(pwd)/custom_configs/http_default.conf"
 
sed -i 's/listen 80/listen 8080/g' "\$(pwd)/custom_configs/conf_default.conf"
sed -i 's/listen \[::\]:80/listen \[::\]:8080/g' "\$(pwd)/custom_configs/conf_default.conf"
sed -i 's/listen 80/listen 8080/g' "\$(pwd)/custom_configs/http_default.conf"
sed -i 's/listen \[::\]:80/listen \[::\]:8080/g' "\$(pwd)/custom_configs/http_default.conf"
 
apptainer instance run \\
  --bind "\$(pwd)/custom_configs/conf_default.conf:/etc/nginx/conf.d/default.conf" \\
  --bind "\$(pwd)/custom_configs/http_default.conf:/etc/nginx/http.d/default.conf" \\
  --bind "\$(pwd)/custom_configs/elasticsearch.ini:/etc/supervisor.d/elasticsearch.ini" \\
  --bind "\$(pwd)/webarena_data/nginx:/var/lib/nginx" \\
  --bind "\$(pwd)/webarena_data/mysql:/var/lib/mysql" \\
  --bind "\$(pwd)/webarena_data/tmp:/tmp" \\
  --bind "\$(pwd)/webarena_data/log:/var/log" \\
  --bind "\$(pwd)/webarena_data/run:/var/run" \\
  --bind "\$(pwd)/webarena_data/esdata:/usr/share/java/elasticsearch/data" \\
  --bind "\$(pwd)/webarena_data/eslog:/usr/share/java/elasticsearch/logs" \\
  --bind "\$(pwd)/webarena_data/magento_var:/var/www/magento2/var" \\
  --bind "\$(pwd)/webarena_data/magento_generated:/var/www/magento2/generated" \\
  --env "ES_JAVA_OPTS=-Xms512m -Xmx512m" \\
  shopping.sif webarena_shopping
 
echo "Instance started. Waiting for services..."
RUNEOF
 
chmod +x run_shopping.sh
 
# =============================================================================
# STEP 6 — First boot
# =============================================================================
echo ""
echo ">>> [6/7] Starting instance for the first time..."
 
sh run_shopping.sh
 
echo "    Waiting for all services to become ready..."
for i in $(seq 1 30); do
    CODE=$(apptainer exec instance://webarena_shopping curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 2>/dev/null || echo "000")
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
 
echo "    Updating Magento base URL to http://localhost:7770/ ..."
apptainer exec instance://webarena_shopping mysql -u magentouser -pMyPassword -h 127.0.0.1 magentodb -e \
    "UPDATE core_config_data SET value='http://localhost:7770/' WHERE path LIKE 'web/%base_url%';"
 
echo "    Flushing Magento cache..."
apptainer exec instance://webarena_shopping php /var/www/magento2/bin/magento cache:flush
 
echo "    Reindexing (this will take a few minutes)..."
apptainer exec instance://webarena_shopping php /var/www/magento2/bin/magento indexer:reindex 2>&1
 
echo "    Flushing cache again after reindex..."
apptainer exec instance://webarena_shopping php /var/www/magento2/bin/magento cache:flush
 
# =============================================================================
# Done
# =============================================================================
echo ""
echo "============================================================"
echo " Setup complete!"
echo " The shopping site is running at http://localhost:8080"
echo " (inside the cluster)"
echo ""
echo " To access from your laptop, run this SSH tunnel command:"
echo "   ssh -i ~/.ssh/unity-privkey.key -L 7770:$(hostname):8080 <your_username>@unity.rc.umass.edu"
echo " Then open http://localhost:7770 in your browser."
echo ""
echo " To stop the instance:  apptainer instance stop webarena_shopping"
echo " To restart next time:  sh run_shopping.sh"
echo "============================================================"