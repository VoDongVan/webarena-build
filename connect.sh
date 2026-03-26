#!/bin/bash
# connect.sh — run this on YOUR LOCAL MACHINE to access WebArena from a browser.
#
# Usage:
#   bash connect.sh <your-unity-username>
#
# What it does:
#   1. SSHes to Unity and reads which compute nodes each service is running on.
#   2. Opens a SOCKS5 proxy on localhost:1080 (via SSH tunnel).
#   3. Prints browser setup instructions and the homepage URL.
#
# Requirements: ssh, standard bash tools.

set -e

UNITY_USER="${1:-}"
if [ -z "$UNITY_USER" ]; then
    echo "Usage: bash connect.sh <your-unity-username>"
    exit 1
fi

UNITY_HOST="unity.rc.umass.edu"
REMOTE_DIR="/scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/homepage"

echo "=== Reading node assignments from Unity... ==="
NODE_INFO=$(ssh "${UNITY_USER}@${UNITY_HOST}" bash <<'REMOTE'
DIR="/scratch3/workspace/vdvo_umass_edu-CS696_S26/webarena_build/homepage"
for svc in shopping shopping_admin reddit gitlab wikipedia homepage; do
    f="$DIR/.${svc}_node"
    if [ -f "$f" ]; then
        val=$(cat "$f" | tr -d '[:space:]')
    else
        val="not-running"
    fi
    echo "${svc}=${val}"
done
REMOTE
)

eval "$NODE_INFO"

echo ""
echo "Node assignments:"
printf "  %-16s %s\n" "Homepage:"       "${homepage:-(not running)}"
printf "  %-16s %s\n" "Shopping:"       "${shopping:-(not running)}"
printf "  %-16s %s\n" "Shopping Admin:" "${shopping_admin:-(not running)}"
printf "  %-16s %s\n" "Reddit:"         "${reddit:-(not running)}"
printf "  %-16s %s\n" "GitLab:"         "${gitlab:-(not running)}"
printf "  %-16s %s\n" "Wikipedia:"      "${wikipedia:-(not running)}"

if [ "$homepage" = "not-running" ]; then
    echo ""
    echo "ERROR: Homepage is not running. Submit the SLURM job first:"
    echo "  sbatch homepage/slurm_homepage.sh"
    exit 1
fi

# Kill any existing SOCKS proxy on port 1080
if lsof -ti:1080 &>/dev/null; then
    echo ""
    echo "Killing existing process on localhost:1080..."
    lsof -ti:1080 | xargs kill -9
fi

echo ""
echo "=== Starting SOCKS5 proxy on localhost:1080... ==="
ssh -D 1080 -N -f "${UNITY_USER}@${UNITY_HOST}"
echo "Proxy running."

HOMEPAGE_URL="http://${homepage}:4399"

echo ""
echo "============================================================"
echo "  Browser setup (one-time)"
echo "============================================================"
echo ""
echo "  Firefox:"
echo "    Settings → General → Network Settings → Manual proxy"
echo "    SOCKS Host: localhost    Port: 1080    SOCKS v5"
echo "    Check: Proxy DNS when using SOCKS v5"
echo ""
echo "  Chrome/Edge (launch from terminal):"
echo "    google-chrome --proxy-server='socks5://localhost:1080'"
echo "    msedge       --proxy-server='socks5://localhost:1080'"
echo ""
echo "============================================================"
echo "  Open this URL in your browser:"
echo ""
echo "    $HOMEPAGE_URL"
echo ""
echo "============================================================"
echo ""
echo "To stop the proxy later, run:"
echo "  lsof -ti:1080 | xargs kill -9"
