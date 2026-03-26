#!/bin/bash
# run_homepage.sh — start the WebArena homepage Flask server on port 4399
# Reads node hostnames from hosts.conf (or from environment variables).
#
# Usage:
#   bash run_homepage.sh
#   SHOPPING_HOST=node001 REDDIT_HOST=node002 bash run_homepage.sh
set -e
cd "$(dirname "$0")"

# Load hosts.conf if present (env vars take precedence)
if [ -f hosts.conf ]; then
    set -a
    source hosts.conf
    set +a
fi

export SHOPPING_HOST="${SHOPPING_HOST:-localhost}"
export SHOPPING_ADMIN_HOST="${SHOPPING_ADMIN_HOST:-localhost}"
export REDDIT_HOST="${REDDIT_HOST:-localhost}"
export GITLAB_HOST="${GITLAB_HOST:-localhost}"
export WIKIPEDIA_HOST="${WIKIPEDIA_HOST:-localhost}"
export MAP_HOST="${MAP_HOST:-localhost}"

echo "=== WebArena Homepage ==="
echo "  Shopping:       http://$SHOPPING_HOST:7770"
echo "  Shopping Admin: http://$SHOPPING_ADMIN_HOST:7780"
echo "  Reddit:         http://$REDDIT_HOST:9999"
echo "  GitLab:         http://$GITLAB_HOST:8023"
echo "  Wikipedia:      http://$WIKIPEDIA_HOST:8888"
echo "  Map:            http://$MAP_HOST:3000"
echo ""
echo "Homepage running at: http://$(hostname):4399"

module load python/3.12.3
export FLASK_APP=app.py
venv/bin/flask run --host=0.0.0.0 --port=4399
