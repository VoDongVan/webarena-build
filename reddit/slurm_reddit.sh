#!/bin/bash
#SBATCH -J webarena_reddit
#SBATCH -p cpu
#SBATCH -N 1
#SBATCH -c 2
#SBATCH --mem=8G
#SBATCH -t 8:00:00
#SBATCH -o /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/reddit/slurm_reddit.out

echo "=== webarena_reddit starting on $(hostname) at $(date) ==="
echo "$(hostname)" > /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/homepage/.reddit_node

bash /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/reddit/run_reddit.sh

echo "=== run_reddit.sh done, keeping node alive ==="
sleep infinity
