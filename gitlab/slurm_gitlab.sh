#!/bin/bash
#SBATCH -J webarena_gitlab
#SBATCH -p cpu
#SBATCH -N 1
#SBATCH -c 4
#SBATCH --mem=32G
#SBATCH -t 8:00:00
#SBATCH -o /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/gitlab/slurm_gitlab.out

echo "=== webarena_gitlab starting on $(hostname) at $(date) ==="
echo "=== SSH tunnel: ssh -L 8023:$(hostname):8023 <username>@unity.rc.umass.edu ==="

bash /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/gitlab/run_gitlab.sh

echo "=== Launching runsvdir (foreground — keeps job alive) ==="
exec apptainer exec instance://webarena_gitlab \
  /opt/gitlab/embedded/bin/runsvdir /opt/gitlab/service
