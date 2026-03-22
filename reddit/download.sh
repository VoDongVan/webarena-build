#!/bin/bash
#SBATCH --job-name=download_reddit
#SBATCH -c 4
#SBATCH -N 1
#SBATCH --mem=64G
#SBATCH -p cpu
#SBATCH -t 24:00:00
#SBATCH -o build_reddit.out

cd /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/reddit/
apptainer build reddit.sif docker-archive:postmill-populated-exposed-withimg.tar
