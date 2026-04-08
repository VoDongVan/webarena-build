#!/bin/bash
#SBATCH -J shopping
#SBATCH -p cpu
#SBATCH -N 1
#SBATCH -c 2
#SBATCH --mem=16G
#SBATCH -t 8:00:00
#SBATCH -o /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/shopping/slurm_shopping.out

echo "=== webarena_shopping starting on $(hostname) at $(date) ==="
echo "$(hostname)" > /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/homepage/.shopping_node

bash /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/shopping/run_shopping.sh

echo "=== run_shopping.sh done, keeping node alive ==="
trap 'echo "=== SIGTERM received, shutting down webarena_shopping gracefully ==="; apptainer instance stop webarena_shopping; exit 0' TERM INT
sleep infinity & wait $!
