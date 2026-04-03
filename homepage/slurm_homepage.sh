#!/bin/bash
#SBATCH -J homepage
#SBATCH -p cpu
#SBATCH -N 1
#SBATCH -c 1
#SBATCH --mem=4G
#SBATCH -t 8:00:00
#SBATCH -o /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/homepage/slurm_homepage.out

echo "=== webarena_homepage starting on $(hostname) at $(date) ==="
echo "$(hostname)" > /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/homepage/.homepage_node

bash /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/homepage/run_homepage.sh

echo "=== run_homepage.sh exited, keeping node alive ==="
sleep infinity
