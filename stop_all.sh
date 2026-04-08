#!/bin/bash
# stop_all.sh — Cancel all WebArena SLURM jobs submitted by launch_all.sh.
#
# Usage (from webarena_build/):
#   bash stop_all.sh

JOBS=(shopping shopping_admin reddit gitlab wikipedia homepage)

echo "=== Cancelling WebArena SLURM jobs ==="
for name in "${JOBS[@]}"; do
    jids=$(squeue --me --name="$name" -h --format="%i" 2>/dev/null)
    if [[ -n "$jids" ]]; then
        echo "Cancelling $name (job IDs: $(echo $jids | tr '\n' ' '))"
        scancel $jids
    else
        echo "No running job found for: $name"
    fi
done

echo ""
echo "=== Done. Remaining jobs: ==="
squeue --me
