#!/bin/bash
# set_up.sh — one-time setup for the WebArena homepage
# Run from the homepage/ directory on any node with internet access.
set -e
cd "$(dirname "$0")"

echo "=== Creating Python venv and installing Flask ==="
module load python/3.12.3
python3 -m venv venv
venv/bin/pip install flask

echo "=== Downloading static figures ==="
BASE="https://raw.githubusercontent.com/web-arena-x/webarena/main/environment_docker/webarena-homepage/static/figures"
FIGURES=(calculator.png cms.png gitlab.png manual1.png manual2.png map.png onestopshop.png password.png reddit.png scratchpad.png wikipedia.png)

mkdir -p static/figures
for fig in "${FIGURES[@]}"; do
    echo "  Downloading $fig..."
    curl -fsSL "$BASE/$fig" -o "static/figures/$fig"
done

echo ""
echo "=== Setup complete ==="
echo "Edit hosts.conf with your SLURM node hostnames, then run:"
echo "  bash run_homepage.sh"
