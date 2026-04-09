#!/bin/bash
#SBATCH -J shopping_admin
#SBATCH -p cpu
#SBATCH -N 1
#SBATCH -c 2
#SBATCH --mem=16G
#SBATCH -t 8:00:00
#SBATCH -o /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/shopping_admin/slurm_shopping_admin.out

echo "=== webarena_shopping_admin starting on $(hostname) at $(date) ==="
# NOTE: .shopping_admin_node is written by run_shopping_admin.sh AFTER MySQL and cache are ready.
# Do NOT write it here — the health check uses it to gate login attempts.

bash /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/shopping_admin/run_shopping_admin.sh

echo "=== run_shopping_admin.sh done, keeping node alive ==="
trap 'echo "=== SIGTERM received, shutting down webarena_shopping_admin gracefully ==="; apptainer instance stop webarena_shopping_admin; exit 0' TERM INT
sleep infinity & wait $!
