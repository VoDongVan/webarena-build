#!/bin/bash

set -e

PROJ=/scratch3/workspace/vdvo_umass_edu-CS696_S26/memorybank
BUILDDIR=$PROJ/../webarena_build
NODEDIR=$BUILDDIR/homepage

echo "=== WebArena baseline starting on $(hostname) at $(date) ==="

# --- Health-check all 6 services (cold start can take 5–15 min) ---
declare -A SVC_PORTS=([shopping]=7770 [shopping_admin]=7780 [reddit]=9999
                      [gitlab]=8023 [wikipedia]=8888 [homepage]=4399)
ALL_OK=false
for attempt in $(seq 1 180); do   # up to 45 minutes (180 × 15s)
    ALL_OK=true
    STATUS_LINE="  [$(( attempt * 15 ))s]"
    for svc in shopping shopping_admin reddit gitlab wikipedia homepage; do
        port="${SVC_PORTS[$svc]}"
        node_file="$NODEDIR/.${svc}_node"
        if [[ ! -f "$node_file" ]]; then
            ALL_OK=false
            STATUS_LINE+=" $svc=NO_NODE"
            continue
        fi
        host=$(cat "$node_file")
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 "http://${host}:${port}" || echo "000")
        if [[ "$code" =~ ^[23] ]]; then
            STATUS_LINE+=" $svc=OK($code)"
        else
            ALL_OK=false
            STATUS_LINE+=" $svc=FAIL($code)"
        fi
    done
    [[ "$ALL_OK" == "true" ]] && break
    echo "$STATUS_LINE"
    sleep 15
done
if [[ "$ALL_OK" == "false" ]]; then
    echo "ERROR: WebArena services did not become healthy after 45 minutes" >&2; exit 1
fi
echo "All services healthy."