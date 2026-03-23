#!/bin/bash
#SBATCH -J webarena_gitlab_setup
#SBATCH -p cpu
#SBATCH -N 1
#SBATCH -c 4
#SBATCH --mem=32G
#SBATCH -t 2:00:00
#SBATCH -o /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/gitlab/setup_gitlab.out

echo "=== webarena_gitlab set_up.sh starting on $(hostname) at $(date) ==="

bash /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/gitlab/set_up.sh

echo "=== set_up.sh finished at $(date) ==="
