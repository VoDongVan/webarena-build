#!/bin/bash
#SBATCH --job-name=download_gitlab
#SBATCH -c 4
#SBATCH -N 1
#SBATCH --mem=64G
#SBATCH -p cpu
#SBATCH -t 24:00:00
#SBATCH -o /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/gitlab/build_gitlab.out

cd /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/gitlab/
wget wget http://metis.lti.cs.cmu.edu/webarena-images/gitlab-populated-final-port8023.tar
apptainer build gitlab.sif docker-archive:gitlab-populated-final-port8023.tar
