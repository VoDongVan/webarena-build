#!/bin/bash
# launch_all.sh — Submit all WebArena SLURM jobs.

set -e

BUILDDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$BUILDDIR"

# 1. Clean up old node-discovery files so the homepage doesn't show "stale" nodes
echo "Cleaning up old service discovery files..."
rm -f homepage/.shopping_node \
      homepage/.shopping_admin_node \
      homepage/.reddit_node \
      homepage/.gitlab_node \
      homepage/.wikipedia_node

echo "=== Submitting independent services ==="
sbatch homepage/slurm_homepage.sh
sbatch reddit/slurm_reddit.sh
sbatch gitlab/slurm_gitlab.sh
sbatch wikipedia/slurm_wikipedia.sh

echo "=== Submitting shopping environment ==="
# We still want to track the shopping node to ensure the admin doesn't fight for resources
SHOP_JID=$(sbatch --parsable shopping/slurm_shopping.sh)
echo "Shopping job: $SHOP_JID submitted."

# Wait for node assignment to ensure --exclude works correctly
SHOP_NODE=""
echo -n "Waiting for Shopping node assignment..."
while true; do
    SHOP_NODE=$(squeue -j "$SHOP_JID" -h --format="%N" 2>/dev/null || true)
    if [[ -n "$SHOP_NODE" && "$SHOP_NODE" != "(None)" && "$SHOP_NODE" != "(Priority)" ]]; then
        echo " Assigned to $SHOP_NODE"
        break
    fi
    echo -n "."
    sleep 5
done

echo "=== Submitting shopping_admin (avoiding $SHOP_NODE) ==="
# Excluding the node ensures the heavy Magento instances don't saturate a single node's RAM
sbatch --exclude="$SHOP_NODE" shopping_admin/slurm_shopping_admin.sh

echo ""
echo "=== All jobs submitted successfully ==="
echo "Check progress: squeue -u $USER"
echo "Once nodes are assigned, check the homepage for status."

# #!/bin/bash
# # launch_all.sh — Submit all WebArena SLURM jobs, ensuring shopping and
# # shopping_admin land on different nodes (they share ports 3306 and 9200).
# #
# # Usage (from webarena_build/):
# #   bash launch_all.sh

# set -e

# BUILDDIR="$(cd "$(dirname "$0")" && pwd)"
# cd "$BUILDDIR"

# echo "=== Submitting homepage, reddit, gitlab, wikipedia (no conflicts) ==="
# sbatch homepage/slurm_homepage.sh
# sbatch reddit/slurm_reddit.sh
# sbatch gitlab/slurm_gitlab.sh
# sbatch wikipedia/slurm_wikipedia.sh

# echo ""
# echo "=== Submitting shopping and waiting for its node assignment ==="
# SHOP_JID=$(sbatch --parsable shopping/slurm_shopping.sh)
# echo "Shopping job: $SHOP_JID — waiting for node..."

# SHOP_NODE=""
# while true; do
#     SHOP_NODE=$(squeue -j "$SHOP_JID" -h --format="%N" 2>/dev/null || true)
#     if [[ -n "$SHOP_NODE" && "$SHOP_NODE" != "(None)" ]]; then
#         break
#     fi
#     sleep 5
# done
# echo "Shopping assigned to: $SHOP_NODE"

# echo ""
# echo "=== Submitting shopping_admin (excluding $SHOP_NODE) ==="
# sbatch --exclude="$SHOP_NODE" shopping_admin/slurm_shopping_admin.sh

# echo ""
# echo "=== All jobs submitted. Monitor with: squeue --me ==="