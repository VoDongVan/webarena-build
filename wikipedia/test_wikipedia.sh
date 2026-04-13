#!/bin/bash
# test_wikipedia.sh — smoke tests for the WebArena Wikipedia (Kiwix) server.
# Run from any node where the server is already up, or on the wikipedia node itself.
# Usage: bash test_wikipedia.sh [HOST] [PORT]
#   HOST defaults to localhost (or the value in homepage/.wikipedia_node)
#   PORT defaults to 8888
#
# NOTE: Wikipedia runs as `apptainer exec ... kiwix-serve &` (background process),
# NOT as an apptainer instance. Section 1 checks for the kiwix-serve process.
#
# Exit code: 0 = all tests passed, 1 = one or more failures.

set -euo pipefail

# ---------- resolve host / port ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_FILE="$SCRIPT_DIR/../homepage/.wikipedia_node"

if [[ -n "${1:-}" ]]; then
    HOST="$1"
elif [[ -f "$NODE_FILE" ]]; then
    HOST="$(cat "$NODE_FILE")"
else
    HOST="localhost"
fi
PORT="${2:-8888}"
BASE="http://$HOST:$PORT"
ZIM_SLUG="wikipedia_en_all_maxi_2022-05"

# Detect whether we are on the server node (enables local process checks)
LOCAL_NODE=$(hostname)
ON_SERVER_NODE=false
if [[ "$LOCAL_NODE" == "$HOST" ]]; then
    ON_SERVER_NODE=true
fi

PASS=0
FAIL=0
SKIP=0

ok()   { echo "  PASS  $1"; (( ++PASS )); }
fail() { echo "  FAIL  $1"; (( ++FAIL )); }
skip() { echo "  SKIP  $1 (not on server node — run on $HOST to check)"; (( ++SKIP )); }

http_check() {
    # http_check LABEL URL [EXPECTED_CODE_PREFIX] [BODY_GREP] [MAX_TIME]
    local label="$1" url="$2" want="${3:-2}" body_pat="${4:-}" max_time="${5:-15}"
    local code
    code=$(curl -s -o /tmp/_wiki_test_body -w "%{http_code}" --max-time "$max_time" "$url" 2>/dev/null || echo "000")
    local first="${code:0:1}"
    if [[ "$first" != "$want" ]]; then
        fail "$label → HTTP $code (wanted ${want}xx)"
        return
    fi
    if [[ -n "$body_pat" ]] && ! grep -qi "$body_pat" /tmp/_wiki_test_body 2>/dev/null; then
        fail "$label → HTTP $code but body missing '$body_pat'"
        return
    fi
    ok "$label → HTTP $code"
}

echo "=========================================="
echo "  WebArena Wikipedia (Kiwix) smoke tests"
echo "  Target  : $BASE"
echo "  ZIM     : $ZIM_SLUG"
echo "  Running on: $LOCAL_NODE"
if $ON_SERVER_NODE; then
    echo "  Mode: full (on server node)"
else
    echo "  Mode: HTTP-only (not on server node; skipping local checks)"
fi
echo "  $(date)"
echo "=========================================="

# ---- 1. Process check ------------------------------------------------
# Wikipedia runs as a bare `apptainer exec ... kiwix-serve &` process,
# not as an apptainer instance. Check for the kiwix-serve process directly.
echo
echo "--- 1. kiwix-serve process ---"
if ! $ON_SERVER_NODE; then
    skip "kiwix-serve process check"
elif pgrep -f "kiwix-serve" &>/dev/null; then
    pid=$(pgrep -f "kiwix-serve" | head -1)
    ok "kiwix-serve running (PID $pid)"
else
    fail "kiwix-serve process not found (is the SLURM job running on this node?)"
fi

# ---- 2. HTTP endpoints -----------------------------------------------
echo
echo "--- 2. HTTP endpoints ---"
# Root: kiwix-serve redirects to the first ZIM's main page, so accept 2xx or 3xx.
root_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$BASE/" 2>/dev/null || echo "000")
if [[ "${root_code:0:1}" == "2" || "${root_code:0:1}" == "3" ]]; then
    ok "Root → HTTP $root_code"
else
    fail "Root → HTTP $root_code (wanted 2xx or 3xx)"
fi

# The WebArena landing page — same URL as test_login.py uses
http_check "WebArena landing page" \
    "$BASE/$ZIM_SLUG/A/User:The_other_Kiwix_guy/Landing" \
    2 "wikipedia\|kiwix"

# Main article page
http_check "Main Page" \
    "$BASE/$ZIM_SLUG/A/Main_Page" \
    2 "wikipedia"

# A real article
http_check "Python article" \
    "$BASE/$ZIM_SLUG/A/Python_(programming_language)" \
    2 "python"

# ---- 3. Search -------------------------------------------------------
echo
echo "--- 3. Search ---"
# Kiwix global search: /search?pattern=<query> (not per-book slug prefix)
search_code=$(curl -s -o /tmp/_wiki_search -w "%{http_code}" --max-time 15 \
    "$BASE/search?pattern=python" 2>/dev/null || echo "000")
if [[ "${search_code:0:1}" == "2" || "${search_code:0:1}" == "3" ]]; then
    ok "Search → HTTP $search_code"
else
    fail "Search → HTTP $search_code (wanted 2xx or 3xx)"
fi

# ---- summary ---------------------------------------------------------
echo
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped"
if (( SKIP > 0 )); then
    echo "  (re-run on $HOST for full local checks)"
fi
echo "=========================================="
(( FAIL == 0 ))
