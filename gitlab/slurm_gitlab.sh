#!/bin/bash
#SBATCH -J webarena_gitlab
#SBATCH -p cpu
#SBATCH -N 1
#SBATCH -c 2
#SBATCH --mem=16G
#SBATCH -t 8:00:00
#SBATCH -o /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/gitlab/slurm_gitlab.out

echo "=== webarena_gitlab starting on $(hostname) at $(date) ==="
echo "$(hostname)" > /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/homepage/.gitlab_node

bash /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/gitlab/run_gitlab.sh

echo "=== Launching runsvdir (foreground — keeps job alive) ==="
exec apptainer exec instance://webarena_gitlab \
  /opt/gitlab/embedded/bin/runsvdir /opt/gitlab/service
