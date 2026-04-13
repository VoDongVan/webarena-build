#!/bin/bash
#SBATCH -J reddit
#SBATCH -p cpu
#SBATCH -N 1
#SBATCH -c 2
#SBATCH --mem=8G
#SBATCH -t 8:00:00
#SBATCH -o /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/reddit/slurm_reddit.out

echo "=== webarena_reddit starting on $(hostname) at $(date) ==="
# NOTE: .reddit_node is written by run_reddit.sh AFTER the readiness check passes.
# Do NOT write it here — tests use it to gate requests.

bash /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/reddit/run_reddit.sh

echo "=== run_reddit.sh done, keeping node alive ==="
trap 'echo "=== SIGTERM received, shutting down webarena_reddit gracefully ==="; apptainer instance stop webarena_reddit; exit 0' TERM INT
sleep infinity & wait $!
