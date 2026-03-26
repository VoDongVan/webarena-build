#!/bin/bash
#SBATCH --job-name=download_wikipedia
#SBATCH -c 4
#SBATCH -N 1
#SBATCH --mem=16G
#SBATCH -p cpu
#SBATCH -t 24:00:00
#SBATCH -o /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/wikipedia/build_wikipedia.out

# =============================================================================
# download.sh — Build the Wikipedia (Kiwix) SIF and download the ZIM data file.
#
# Unlike other WebArena services, kiwix-serve has no pre-built Docker tar on
# the CMU mirror. The CMU mirror only hosts the ZIM data file. The Docker
# image is pulled directly from the GitHub Container Registry.
#
#   Other services:  wget <name>.tar  +  apptainer build docker-archive:<name>.tar
#   Wikipedia:       apptainer pull docker://ghcr.io/kiwix/kiwix-serve:3.3.0
#                    wget wikipedia_en_all_maxi_2022-05.zim   (data file, ~85 GB)
#
# Run as a SLURM job:
#   sbatch download.sh
# Or interactively from a compute node (salloc):
#   bash download.sh
# =============================================================================

cd /scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/wikipedia/

# -----------------------------------------------------------------------------
# Step 1 — Pull kiwix-serve Docker image from registry and build SIF
# -----------------------------------------------------------------------------
if [ ! -f wikipedia.sif ]; then
    echo ">>> Pulling ghcr.io/kiwix/kiwix-serve:3.3.0 and building wikipedia.sif ..."
    apptainer pull wikipedia.sif docker://ghcr.io/kiwix/kiwix-serve:3.3.0
    echo ">>> wikipedia.sif built."
else
    echo ">>> wikipedia.sif already exists, skipping."
fi

# -----------------------------------------------------------------------------
# Step 2 — Download the Wikipedia ZIM data file from the CMU mirror (~85 GB)
# -----------------------------------------------------------------------------
mkdir -p data

if [ ! -f data/wikipedia_en_all_maxi_2022-05.zim ]; then
    echo ">>> Downloading Wikipedia ZIM file from CMU mirror (~85 GB)..."
    wget -c -P data/ http://metis.lti.cs.cmu.edu/webarena-images/wikipedia_en_all_maxi_2022-05.zim
    echo ">>> ZIM download complete."
else
    echo ">>> data/wikipedia_en_all_maxi_2022-05.zim already exists, skipping."
fi

echo ""
echo "=== Done. Run set_up.sh next, or sbatch slurm_wikipedia.sh to start. ==="
