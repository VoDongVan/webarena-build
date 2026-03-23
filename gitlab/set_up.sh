#!/bin/bash
# =============================================================================
# set_up.sh — One-time setup for WebArena GitLab on Unity HPC
# Run this ONCE from a compute node after salloc.
# After this completes, use run_gitlab.sh for all future starts.
# =============================================================================

set -e

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"
echo "Working directory: $WORKDIR"

# =============================================================================
# STEP 1 — SIF check
# =============================================================================
echo ""
echo ">>> [1/6] Checking for Apptainer SIF..."

if [ ! -f gitlab.sif ]; then
    echo "    ERROR: gitlab.sif not found. Run download.sh first."
    echo "    (sbatch download.sh  — requires gitlab-populated-final-port8023.tar in this directory)"
    exit 1
fi
echo "    gitlab.sif found."

# =============================================================================
# STEP 2 — Create directory structure
# =============================================================================
echo ""
echo ">>> [2/6] Creating bind-mount directories..."

mkdir -p webarena_data/gitlab_data
mkdir -p webarena_data/etc_gitlab
mkdir -p webarena_data/log_gitlab
mkdir -p webarena_data/run
mkdir -p webarena_data/tmp

# =============================================================================
# STEP 3 — Extract data from SIF (idempotent — skip if already done)
# =============================================================================
echo ""
echo ">>> [3/6] Extracting writable data from SIF (this may take several minutes)..."

if [ -z "$(ls -A webarena_data/gitlab_data/)" ]; then
    echo "    Extracting /var/opt/gitlab (all GitLab state: postgres, redis, repos)..."
    echo "    This is large — expect 5-15 minutes depending on image size."
    apptainer exec gitlab.sif cp -a /var/opt/gitlab/. webarena_data/gitlab_data/
    echo "    Done."
else
    echo "    gitlab_data already extracted, skipping."
fi

if [ -z "$(ls -A webarena_data/etc_gitlab/)" ]; then
    echo "    Extracting /etc/gitlab (config files including gitlab.rb)..."
    apptainer exec gitlab.sif cp -a /etc/gitlab/. webarena_data/etc_gitlab/
    echo "    Done."
else
    echo "    etc_gitlab already extracted, skipping."
fi

if [ -z "$(ls -A webarena_data/log_gitlab/)" ]; then
    echo "    Extracting /var/log/gitlab (service logs)..."
    apptainer exec gitlab.sif cp -a /var/log/gitlab/. webarena_data/log_gitlab/
    echo "    Done."
else
    echo "    log_gitlab already extracted, skipping."
fi

# Remove stale postmaster.pid — postgres refuses to start if this exists
rm -f webarena_data/gitlab_data/postgresql/data/postmaster.pid
echo "    Removed stale postmaster.pid (if any)."

# PostgreSQL requires the data directory is not group/world-writable
if [ -d webarena_data/gitlab_data/postgresql/data ]; then
    chmod 700 webarena_data/gitlab_data/postgresql/data
fi

# =============================================================================
# STEP 4 — Pre-patch external_url in gitlab.rb
# =============================================================================
echo ""
echo ">>> [4/6] Patching external_url in gitlab.rb..."

if [ -f webarena_data/etc_gitlab/gitlab.rb ]; then
    sed -i "s|^external_url.*|external_url 'http://localhost:8023'|" webarena_data/etc_gitlab/gitlab.rb
    echo "    external_url set to http://localhost:8023"
else
    echo "    WARNING: webarena_data/etc_gitlab/gitlab.rb not found — skipping patch."
fi

# =============================================================================
# STEP 5 — Generate run_gitlab.sh and slurm_gitlab.sh
# =============================================================================
echo ""
echo ">>> [5/6] Generating run_gitlab.sh and slurm_gitlab.sh..."

cat > run_gitlab.sh << 'RUNEOF'
#!/bin/bash
# run_gitlab.sh — Start the WebArena GitLab instance.
# Run this every time you want to start the site after set_up.sh has been run once.

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"

echo "=== GitLab starting on $(hostname) at $(date) ==="
echo "=== SSH tunnel: ssh -L 8023:$(hostname):8023 <username>@unity.rc.umass.edu ==="

# PostgreSQL requires its data dir is not group/world-writable
if [ -d "$WORKDIR/webarena_data/gitlab_data/postgresql/data" ]; then
    chmod 700 "$WORKDIR/webarena_data/gitlab_data/postgresql/data"
fi
# Remove stale postmaster.pid (prevents postgres startup)
rm -f "$WORKDIR/webarena_data/gitlab_data/postgresql/data/postmaster.pid"

# Writable runtime dirs
chmod -R 755 "$WORKDIR/webarena_data/etc_gitlab"
chmod -R 755 "$WORKDIR/webarena_data/log_gitlab"
chmod -R 777 "$WORKDIR/webarena_data/run"
chmod -R 777 "$WORKDIR/webarena_data/tmp"

apptainer instance start \
  --bind "$WORKDIR/webarena_data/gitlab_data:/var/opt/gitlab" \
  --bind "$WORKDIR/webarena_data/etc_gitlab:/etc/gitlab" \
  --bind "$WORKDIR/webarena_data/log_gitlab:/var/log/gitlab" \
  --bind "$WORKDIR/webarena_data/run:/run" \
  --bind "$WORKDIR/webarena_data/tmp:/tmp" \
  gitlab.sif webarena_gitlab

# The SIF's %startscript is empty — launch runit explicitly
echo "Instance started. Launching runsvdir-start..."
apptainer exec instance://webarena_gitlab \
  /opt/gitlab/embedded/bin/runsvdir-start &

echo "Waiting for GitLab to become ready (up to 10 minutes)..."
for i in $(seq 1 60); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8023 2>/dev/null || echo "000")
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
        echo "GitLab ready (HTTP $CODE)."
        break
    fi
    echo "Attempt $i/60: HTTP $CODE, waiting 10s..."
    sleep 10
done
RUNEOF

chmod +x run_gitlab.sh

cat > slurm_gitlab.sh << 'EOF'
#!/bin/bash
#SBATCH -J webarena_gitlab
#SBATCH -p cpu
#SBATCH -N 1
#SBATCH -c 4
#SBATCH --mem=32G
#SBATCH -t 8:00:00
#SBATCH -o /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/gitlab/slurm_gitlab.out

echo "=== webarena_gitlab starting on $(hostname) at $(date) ==="

bash /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/gitlab/run_gitlab.sh

echo "=== run_gitlab.sh done, keeping node alive ==="
sleep infinity
EOF

chmod +x slurm_gitlab.sh

# =============================================================================
# STEP 6 — First boot + gitlab-ctl reconfigure
# =============================================================================
echo ""
echo ">>> [6/6] First boot and initial reconfigure..."

bash run_gitlab.sh

echo ""
echo "Running gitlab-ctl reconfigure to apply external_url..."
apptainer exec instance://webarena_gitlab gitlab-ctl reconfigure
echo "reconfigure complete."

# =============================================================================
# Done
# =============================================================================
echo ""
echo "============================================================"
echo " Setup complete!"
echo " GitLab is running at http://localhost:8023"
echo " (inside the cluster)"
echo ""
echo " To access from your laptop:"
echo "   ssh -L 8023:$(hostname):8023 <username>@unity.rc.umass.edu"
echo "   Then open http://localhost:8023/explore"
echo ""
echo " To stop:   apptainer instance stop webarena_gitlab"
echo " To restart: bash run_gitlab.sh"
echo " SLURM:      sbatch slurm_gitlab.sh"
echo "============================================================"
