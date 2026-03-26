#!/bin/bash
# =============================================================================
# set_up.sh — One-time setup for WebArena Wikipedia (Kiwix) on Unity HPC
# Run this ONCE from a compute node after download.sh has completed.
# After this completes, use run_wikipedia.sh for all future starts.
# =============================================================================

set -e

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"
echo "Working directory: $WORKDIR"

# =============================================================================
# STEP 1 — Check for SIF
# =============================================================================
echo ""
echo ">>> [1/2] Checking for Apptainer SIF..."

if [ ! -f wikipedia.sif ]; then
    echo "    ERROR: wikipedia.sif not found. Run download.sh first."
    echo "    (sbatch download.sh)"
    exit 1
fi
echo "    wikipedia.sif found."

# =============================================================================
# STEP 2 — Check for ZIM data file
# =============================================================================
echo ""
echo ">>> [2/2] Checking for Wikipedia ZIM data file..."

if [ ! -f data/wikipedia_en_all_maxi_2022-05.zim ]; then
    echo "    ERROR: data/wikipedia_en_all_maxi_2022-05.zim not found. Run download.sh first."
    exit 1
fi
echo "    data/wikipedia_en_all_maxi_2022-05.zim found."

# =============================================================================
# Done — Wikipedia has no database to extract; the ZIM file is the data.
# =============================================================================
echo ""
echo "============================================================"
echo " Setup complete!"
echo ""
echo " To start the Wikipedia server, run:"
echo "   bash run_wikipedia.sh          (interactive, current node)"
echo "   sbatch slurm_wikipedia.sh      (SLURM batch job)"
echo ""
echo " Site will be available at:"
echo "   http://localhost:8888/wikipedia_en_all_maxi_2022-05/A/User:The_other_Kiwix_guy/Landing"
echo ""
echo " To stop: apptainer instance stop webarena_wikipedia"
echo "============================================================"
