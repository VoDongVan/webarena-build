#!/bin/bash
#SBATCH -J webarena_shopping_admin
#SBATCH -p cpu
#SBATCH -N 1
#SBATCH -c 2
#SBATCH --mem=16G
#SBATCH -t 8:00:00
#SBATCH -o /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/shopping_admin/slurm_shopping_admin.out

echo "=== webarena_shopping_admin starting on $(hostname) at $(date) ==="
echo "$(hostname)" > /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/homepage/.shopping_admin_node

bash /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/shopping_admin/run_shopping_admin.sh

echo "=== run_shopping_admin.sh done, keeping node alive ==="
sleep infinity
