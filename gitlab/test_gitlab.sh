#!/bin/bash
# test_gitlab.sh — smoke tests for the webarena_gitlab Apptainer instance.
# Run from any node where the instance is already up, or on the gitlab node itself.
# Usage: bash test_gitlab.sh [HOST] [PORT]
#   HOST defaults to localhost (or the value in homepage/.gitlab_node)
#   PORT defaults to 8023
#
# Exit code: 0 = all tests passed, 1 = one or more failures.

set -euo pipefail

# ---------- resolve host / port ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_FILE="$SCRIPT_DIR/../homepage/.gitlab_node"

if [[ -n "${1:-}" ]]; then
    HOST="$1"
elif [[ -f "$NODE_FILE" ]]; then
    HOST="$(cat "$NODE_FILE")"
else
    HOST="localhost"
fi
PORT="${2:-8023}"
BASE="http://$HOST:$PORT"
INST="webarena_gitlab"

# Detect whether we are on the server node (enables local apptainer checks)
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
    local label="$1" url="$2" want="${3:-2}" body_pat="${4:-}" max_time="${5:-30}"
    local code
    code=$(curl -s -o /tmp/_gitlab_test_body -w "%{http_code}" --max-time "$max_time" "$url" 2>/dev/null || echo "000")
    local first="${code:0:1}"
    if [[ "$first" != "$want" ]]; then
        fail "$label → HTTP $code (wanted ${want}xx)"
        return
    fi
    if [[ -n "$body_pat" ]] && ! grep -qi "$body_pat" /tmp/_gitlab_test_body 2>/dev/null; then
        fail "$label → HTTP $code but body missing '$body_pat'"
        return
    fi
    ok "$label → HTTP $code"
}

echo "=========================================="
echo "  WebArena GitLab smoke tests"
echo "  Target  : $BASE"
echo "  Instance: $INST"
echo "  Running on: $LOCAL_NODE"
if $ON_SERVER_NODE; then
    echo "  Mode: full (on server node)"
else
    echo "  Mode: HTTP-only (not on server node; skipping local checks)"
fi
echo "  $(date)"
echo "=========================================="

# ---- 1. Apptainer instance -------------------------------------------
echo
echo "--- 1. Apptainer instance ---"
if ! $ON_SERVER_NODE; then
    skip "instance list"
elif apptainer instance list 2>/dev/null | grep -q "$INST"; then
    ok "instance $INST is listed"
else
    fail "instance $INST not found — is it running?"
fi

# ---- 2. Health endpoint ----------------------------------------------
# GitLab's /-/health returns 200 only when all internal services are ready.
# It can return 500 or timeout if Puma/PostgreSQL/Redis haven't fully started.
echo
echo "--- 2. Health endpoint ---"
health_code=$(curl -s -o /tmp/_gitlab_test_body -w "%{http_code}" --max-time 30 \
    "$BASE/-/health" 2>/dev/null || echo "000")
if [[ "$health_code" == "200" ]]; then
    ok "/-/health → HTTP 200"
else
    # Non-200 is a failure but we show what we got so it's easier to diagnose
    fail "/-/health → HTTP $health_code (wanted 200; GitLab may still be warming up)"
fi

# ---- 3. HTTP pages ---------------------------------------------------
echo
echo "--- 3. HTTP pages ---"
# Root: redirects to dashboard (if logged in) or sign_in (if not). Accept 2xx or 3xx.
root_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$BASE/" 2>/dev/null || echo "000")
if [[ "${root_code:0:1}" == "2" || "${root_code:0:1}" == "3" ]]; then
    ok "Root → HTTP $root_code"
else
    fail "Root → HTTP $root_code (wanted 2xx or 3xx)"
fi

http_check "Sign-in page"     "$BASE/users/sign_in"    2 "sign in\|gitlab\|username\|password"
http_check "Explore projects" "$BASE/explore/projects" 2 "project\|explore\|gitlab"

# ---- 4. REST API -----------------------------------------------------
echo
echo "--- 4. REST API ---"
# Public project list — GitLab CE returns public repos without auth
api_code=$(curl -s -o /tmp/_gitlab_api_body -w "%{http_code}" --max-time 30 \
    "$BASE/api/v4/projects?per_page=5" 2>/dev/null || echo "000")
if [[ "${api_code:0:1}" == "2" ]]; then
    project_count=$(python3 -c "
import json, sys
try:
    d = json.load(open('/tmp/_gitlab_api_body'))
    print(len(d))
except Exception:
    print('?')
" 2>/dev/null || echo "?")
    ok "GET /api/v4/projects → HTTP $api_code ($project_count projects)"
else
    fail "GET /api/v4/projects → HTTP $api_code"
fi

# ---- 5. Login (API token via personal access tokens endpoint) --------
# GitLab CE supports creating a personal access token via the API when using
# username + password. We use the session-cookie approach as a simpler check.
echo
echo "--- 5. Login check ---"
# Step 1: GET /users/sign_in to obtain CSRF token
rm -f /tmp/_gitlab_cookies
curl -s -c /tmp/_gitlab_cookies -b /tmp/_gitlab_cookies \
     --max-time 15 "$BASE/users/sign_in" -o /tmp/_gitlab_login_form 2>/dev/null || true

csrf_token=$(grep -o 'name="authenticity_token"[^>]*value="[^"]*"' /tmp/_gitlab_login_form 2>/dev/null \
    | sed 's/.*value="//;s/"//' | head -1 || echo "")

if [[ -z "$csrf_token" ]]; then
    fail "Login CSRF token not found on /users/sign_in"
else
    ok "Login CSRF token obtained (${csrf_token:0:20}...)"

    # Step 2: POST credentials to /users/sign_in
    login_http=$(curl -s \
        -c /tmp/_gitlab_cookies -b /tmp/_gitlab_cookies \
        --max-time 15 \
        -X POST "$BASE/users/sign_in" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "user[login]=byteblaze" \
        --data-urlencode "user[password]=hello1234" \
        --data-urlencode "authenticity_token=$csrf_token" \
        -w "%{http_code}" -o /tmp/_gitlab_login_resp \
        2>/dev/null || echo "000")

    if [[ "${login_http:0:1}" == "2" || "${login_http:0:1}" == "3" ]]; then
        # Check we're not back on the sign_in page (which means login failed)
        final_url=$(grep -i "^Location:" /tmp/_gitlab_login_resp 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo "")
        if [[ "$login_http" == "302" && "$final_url" != *"sign_in"* ]]; then
            ok "Login → HTTP 302 (credentials accepted, redirecting to $final_url)"
        elif grep -qi "invalid\|incorrect" /tmp/_gitlab_login_resp 2>/dev/null; then
            fail "Login → HTTP $login_http but credentials rejected"
        else
            ok "Login → HTTP $login_http (no error found)"
        fi
    else
        fail "Login POST → HTTP $login_http (wanted 2xx or 3xx)"
    fi
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
