#!/bin/bash
# run_wikipedia.sh — Start the WebArena Wikipedia (Kiwix) instance.
# Run this every time you want to start the site after set_up.sh has been run once.

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"

echo "=== Wikipedia (Kiwix) starting on $(hostname) at $(date) ==="
echo "=== SSH tunnel: ssh -L 8888:$(hostname):8888 <username>@unity.rc.umass.edu ==="

ZIM="$WORKDIR/data/wikipedia_en_all_maxi_2022-05.zim"

if [ ! -f "$ZIM" ]; then
    echo "ERROR: ZIM file not found at $ZIM"
    echo "       Run set_up.sh first."
    exit 1
fi

if [ ! -f "$WORKDIR/wikipedia.sif" ]; then
    echo "ERROR: wikipedia.sif not found."
    echo "       Run set_up.sh first."
    exit 1
fi

apptainer instance start \
  --bind "$WORKDIR/data:/data" \
  "$WORKDIR/wikipedia.sif" webarena_wikipedia

# The SIF's %startscript runs kiwix-serve with no args — launch it explicitly on port 8888
echo "Instance started. Launching kiwix-serve on port 8888..."
apptainer exec instance://webarena_wikipedia \
  kiwix-serve --port 8888 /data/wikipedia_en_all_maxi_2022-05.zim &

echo "Waiting for service to become ready..."
for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8888 2>/dev/null || echo "000")
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
        echo "Service ready (HTTP $CODE)."
        break
    fi
    echo "Attempt $i/30: HTTP $CODE, waiting 5s..."
    sleep 5
done
