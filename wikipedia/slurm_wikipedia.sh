#!/bin/bash
#SBATCH -J wikipedia
#SBATCH -p cpu
#SBATCH -N 1
#SBATCH -c 2
#SBATCH --mem=8G
#SBATCH -t 8:00:00
#SBATCH -o /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/wikipedia/slurm_wikipedia.out

echo "=== webarena_wikipedia starting on $(hostname) at $(date) ==="
echo "$(hostname)" > /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/homepage/.wikipedia_node

bash /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/wikipedia/run_wikipedia.sh

echo "=== run_wikipedia.sh done, keeping node alive ==="
sleep infinity
