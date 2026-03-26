#!/bin/bash
# launch_all.sh — Submit all WebArena SLURM jobs, ensuring shopping and
# shopping_admin land on different nodes (they share ports 3306 and 9200).
#
# Usage (from webarena_build/):
#   bash launch_all.sh

set -e

BUILDDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$BUILDDIR"

echo "=== Submitting homepage, reddit, gitlab (no conflicts) ==="
sbatch homepage/slurm_homepage.sh
sbatch reddit/slurm_reddit.sh
sbatch gitlab/slurm_gitlab.sh

echo ""
echo "=== Submitting shopping and waiting for its node assignment ==="
SHOP_JID=$(sbatch --parsable shopping/slurm_shopping.sh)
echo "Shopping job: $SHOP_JID — waiting for node..."

SHOP_NODE=""
while true; do
    SHOP_NODE=$(squeue -j "$SHOP_JID" -h --format="%N" 2>/dev/null || true)
    if [[ -n "$SHOP_NODE" && "$SHOP_NODE" != "(None)" ]]; then
        break
    fi
    sleep 5
done
echo "Shopping assigned to: $SHOP_NODE"

echo ""
echo "=== Submitting shopping_admin (excluding $SHOP_NODE) ==="
sbatch --exclude="$SHOP_NODE" shopping_admin/slurm_shopping_admin.sh

echo ""
echo "=== All jobs submitted. Monitor with: squeue --me ==="
