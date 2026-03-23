#!/bin/bash
# =============================================================================
# set_up.sh — One-time setup for WebArena Reddit (Postmill) on Unity HPC
# Run this ONCE from a compute node after salloc.
# After this completes, use run_reddit.sh for all future starts.
# =============================================================================

set -e

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"
echo "Working directory: $WORKDIR"

# =============================================================================
# STEP 1 — SIF check
# =============================================================================
echo ""
echo ">>> [1/5] Checking for Apptainer SIF..."

if [ ! -f reddit.sif ]; then
    echo "    ERROR: reddit.sif not found. Run download.sh first."
    exit 1
fi
echo "    reddit.sif found."

# =============================================================================
# STEP 2 — Create directory structure
# =============================================================================
echo ""
echo ">>> [2/5] Creating bind-mount directories..."

mkdir -p custom_configs
mkdir -p webarena_data/pgsql
mkdir -p webarena_data/nginx_tmp/client_body
mkdir -p webarena_data/nginx_tmp/proxy
mkdir -p webarena_data/nginx_tmp/fastcgi
mkdir -p webarena_data/nginx_tmp/uwsgi
mkdir -p webarena_data/nginx_tmp/scgi
mkdir -p webarena_data/run/nginx
mkdir -p webarena_data/run/postgresql
mkdir -p webarena_data/log/nginx
mkdir -p webarena_data/tmp
mkdir -p webarena_data/postmill_var

# =============================================================================
# STEP 3 — Extract data from SIF (idempotent)
# =============================================================================
echo ""
echo ">>> [3/5] Extracting writable data from SIF (skips if already done)..."

if [ -z "$(ls -A webarena_data/pgsql/)" ]; then
    echo "    Extracting PostgreSQL data..."
    apptainer exec reddit.sif cp -a /usr/local/pgsql/data/. webarena_data/pgsql/
    # Remove stale postmaster.pid — postgres refuses to start if this exists
    rm -f webarena_data/pgsql/postmaster.pid
    # PostgreSQL requires the data directory is not group/world-writable
    chmod -R 700 webarena_data/pgsql
    echo "    Done."
else
    echo "    PostgreSQL data already extracted, skipping."
fi

if [ -z "$(ls -A webarena_data/postmill_var/)" ]; then
    echo "    Extracting Postmill var directory (Symfony cache/logs/sessions)..."
    apptainer exec reddit.sif cp -a /var/www/html/var/. webarena_data/postmill_var/
    chmod -R 777 webarena_data/postmill_var
    echo "    Done."
else
    echo "    Postmill var already extracted, skipping."
fi

# =============================================================================
# STEP 4 — Create custom config files
# =============================================================================
echo ""
echo ">>> [4/5] Creating custom config files..."

echo "    Patching nginx vhost config (port 80 → 9999)..."
apptainer exec reddit.sif cat /etc/nginx/conf.d/default.conf > custom_configs/conf_default.conf
sed -i 's/listen 80/listen 9999/g' custom_configs/conf_default.conf
sed -i 's/listen \[::\]:80/listen \[::\]:9999/g' custom_configs/conf_default.conf

echo "    Writing start.sh (bypasses docker-entrypoint.sh which requires root)..."
cat > custom_configs/start.sh << 'EOF'
#!/bin/sh
exec supervisord -n -j /supervisord.pid -c /etc/supervisord.conf
EOF
chmod +x custom_configs/start.sh

echo "    Writing pgsql.ini (removes 'su postgres' — runs postgres as current user)..."
cat > custom_configs/pgsql.ini << 'EOF'
[program:postgres]
command=postgres -D /usr/local/pgsql/data
autostart=true
autorestart=true
priority=1
startretries=3
stopwaitsecs=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

# =============================================================================
# STEP 5 — Generate run_reddit.sh
# =============================================================================
echo ""
echo ">>> [5/5] Generating run_reddit.sh and slurm_reddit.sh..."

cat > run_reddit.sh << 'RUNEOF'
#!/bin/bash
# run_reddit.sh — Start the WebArena Reddit (Postmill) instance.
# Run this every time you want to start the site after set_up.sh has been run once.

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"

echo "=== Reddit (Postmill) starting on $(hostname) at $(date) ==="
echo "=== SSH tunnel: ssh -L 9999:$(hostname):9999 <username>@unity.rc.umass.edu ==="

# PostgreSQL requires its data dir is not group/world-writable
chmod -R 700 "$WORKDIR/webarena_data/pgsql"
# Remove stale postmaster.pid if present (prevents postgres startup)
rm -f "$WORKDIR/webarena_data/pgsql/postmaster.pid"
# Everything else should be freely writable
chmod -R 777 "$WORKDIR/webarena_data/nginx_tmp"
chmod -R 777 "$WORKDIR/webarena_data/run"
chmod -R 777 "$WORKDIR/webarena_data/log"
chmod -R 777 "$WORKDIR/webarena_data/tmp"
chmod -R 777 "$WORKDIR/webarena_data/postmill_var"

# Ensure nginx tmp dirs exist
mkdir -p "$WORKDIR/webarena_data/nginx_tmp/client_body"
mkdir -p "$WORKDIR/webarena_data/nginx_tmp/proxy"
mkdir -p "$WORKDIR/webarena_data/nginx_tmp/fastcgi"
mkdir -p "$WORKDIR/webarena_data/nginx_tmp/uwsgi"
mkdir -p "$WORKDIR/webarena_data/nginx_tmp/scgi"
mkdir -p "$WORKDIR/webarena_data/run/nginx"
mkdir -p "$WORKDIR/webarena_data/run/postgresql"
mkdir -p "$WORKDIR/webarena_data/log/nginx"

# Re-extract + re-patch nginx vhost each run
apptainer exec reddit.sif cat /etc/nginx/conf.d/default.conf > "$WORKDIR/custom_configs/conf_default.conf"
sed -i 's/listen 80/listen 9999/g' "$WORKDIR/custom_configs/conf_default.conf"
sed -i 's/listen \[::\]:80/listen \[::\]:9999/g' "$WORKDIR/custom_configs/conf_default.conf"

# Re-write start.sh each run
cat > "$WORKDIR/custom_configs/start.sh" << 'EOF'
#!/bin/sh
exec supervisord -n -j /supervisord.pid -c /etc/supervisord.conf
EOF
chmod +x "$WORKDIR/custom_configs/start.sh"

apptainer instance start \
  --bind "$WORKDIR/custom_configs/start.sh:/docker-entrypoint.sh" \
  --bind "$WORKDIR/custom_configs/pgsql.ini:/etc/supervisor.d/pgsql.ini" \
  --bind "$WORKDIR/custom_configs/conf_default.conf:/etc/nginx/conf.d/default.conf" \
  --bind "$WORKDIR/webarena_data/pgsql:/usr/local/pgsql/data" \
  --bind "$WORKDIR/webarena_data/nginx_tmp:/var/tmp/nginx" \
  --bind "$WORKDIR/webarena_data/run:/run" \
  --bind "$WORKDIR/webarena_data/run:/var/run" \
  --bind "$WORKDIR/webarena_data/log:/var/log" \
  --bind "$WORKDIR/webarena_data/tmp:/tmp" \
  --bind "$WORKDIR/webarena_data/postmill_var:/var/www/html/var" \
  reddit.sif webarena_reddit

# The SIF's %startscript is empty — launch supervisord explicitly
echo "Instance started. Launching supervisord..."
apptainer exec instance://webarena_reddit \
  supervisord -n -j /supervisord.pid -c /etc/supervisord.conf &

echo "Waiting for services to become ready..."
for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9999 2>/dev/null || echo "000")
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
        echo "Services ready (HTTP $CODE)."
        break
    fi
    echo "Attempt $i/30: HTTP $CODE, waiting 5s..."
    sleep 5
done
RUNEOF

chmod +x run_reddit.sh

cat > slurm_reddit.sh << 'EOF'
#!/bin/bash
#SBATCH -J webarena_reddit
#SBATCH -p cpu
#SBATCH -N 1
#SBATCH -c 4
#SBATCH --mem=32G
#SBATCH -t 8:00:00
#SBATCH -o /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/reddit/slurm_reddit.out

echo "=== webarena_reddit starting on $(hostname) at $(date) ==="

bash /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/reddit/run_reddit.sh

echo "=== run_reddit.sh done, keeping node alive ==="
sleep infinity
EOF

chmod +x slurm_reddit.sh

# =============================================================================
# Done
# =============================================================================
echo ""
echo "============================================================"
echo " Setup files generated!"
echo ""
echo " To start the Reddit site, run:"
echo "   bash run_reddit.sh          (interactive, current node)"
echo "   sbatch slurm_reddit.sh      (SLURM batch job)"
echo ""
echo " Site will be available at http://localhost:9999"
echo " SSH tunnel: ssh -L 9999:<node>:9999 <username>@unity.rc.umass.edu"
echo ""
echo " To stop: apptainer instance stop webarena_reddit"
echo "          (or scancel <jobid> if using SLURM)"
echo "============================================================"
