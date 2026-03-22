#!/bin/bash
#SBATCH -c 4
#SBATCH -N 1
#SBATCH --mem=64G
#SBATCH -p cpu
#SBATCH -t 08:00:00
#SBATCH -o build_shopping_admin.out

cd /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/shopping_admin/
apptainer build shopping_admin.sif docker-archive:shopping_admin_final_0719.tar
