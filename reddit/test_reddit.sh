#!/bin/bash
# test_reddit.sh — smoke tests for the webarena_reddit Apptainer instance.
# Run from any node where the instance is already up, or on the reddit node itself.
# Usage: bash test_reddit.sh [HOST] [PORT]
#   HOST defaults to localhost (or the value in homepage/.reddit_node)
#   PORT defaults to 9999
#
# Exit code: 0 = all tests passed, 1 = one or more failures.

set -euo pipefail

# ---------- resolve host / port ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_FILE="$SCRIPT_DIR/../homepage/.reddit_node"

if [[ -n "${1:-}" ]]; then
    HOST="$1"
elif [[ -f "$NODE_FILE" ]]; then
    HOST="$(cat "$NODE_FILE")"
else
    HOST="localhost"
fi
PORT="${2:-9999}"
BASE="http://$HOST:$PORT"
INST="webarena_reddit"

# Detect whether we are on the server node (enables local apptainer/process checks)
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
    # http_check LABEL URL [EXPECTED_CODE_PREFIX] [BODY_GREP]
    local label="$1" url="$2" want="${3:-2}" body_pat="${4:-}"
    local out code
    out=$(curl -s -o /tmp/_reddit_test_body -w "%{http_code}" --max-time 15 "$url" 2>/dev/null || echo "000")
    code="$out"
    local first="${code:0:1}"
    if [[ "$first" != "$want" ]]; then
        fail "$label → HTTP $code (wanted ${want}xx)"
        return
    fi
    if [[ -n "$body_pat" ]] && ! grep -qi "$body_pat" /tmp/_reddit_test_body 2>/dev/null; then
        fail "$label → HTTP $code but body missing '$body_pat'"
        return
    fi
    ok "$label → HTTP $code"
}

apptainer_exec() {
    apptainer exec instance://"$INST" "$@"
}

echo "=========================================="
echo "  WebArena Reddit (Postmill) smoke tests"
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

# ---- 1. Instance alive -----------------------------------------------
echo
echo "--- 1. Apptainer instance ---"
if ! $ON_SERVER_NODE; then
    skip "instance list"
elif apptainer instance list 2>/dev/null | grep -q "$INST"; then
    ok "instance $INST is listed"
else
    fail "instance $INST not found — is it running?"
fi

# ---- 2. Supervisor process status ------------------------------------
echo
echo "--- 2. Supervisord process status ---"
for svc in nginx php-fpm postgres; do
    if ! $ON_SERVER_NODE; then
        skip "$svc"
    else
        state=$(apptainer_exec supervisorctl status "$svc" 2>/dev/null | awk '{print $2}' || echo "ERROR")
        if [[ "$state" == "RUNNING" ]]; then
            ok "$svc RUNNING"
        else
            fail "$svc → $state"
        fi
    fi
done

# ---- 3. PostgreSQL connectivity & data -------------------------------
# Connect via Unix socket (no -h flag): pg_hba.conf uses "trust" for local
# socket connections. TCP (127.0.0.1) requires a password.
echo
echo "--- 3. PostgreSQL ---"
if ! $ON_SERVER_NODE; then
    skip "PostgreSQL connectivity"
    skip "PostgreSQL user count"
    skip "PostgreSQL forum count"
    skip "PostgreSQL submission count"
else
    if apptainer_exec psql -U postmill -d postmill \
            -c "SELECT 1" &>/dev/null 2>&1; then
        ok "PostgreSQL accepts connections (Unix socket)"
    else
        fail "PostgreSQL not accepting connections"
    fi

    user_count=$(apptainer_exec psql -U postmill -d postmill \
        -tAc "SELECT COUNT(*) FROM users" 2>/dev/null | tr -d '[:space:]' || echo 0)
    if (( user_count > 0 )); then
        ok "PostgreSQL user count = $user_count (>0)"
    else
        fail "PostgreSQL user count = $user_count (expected >0)"
    fi

    forum_count=$(apptainer_exec psql -U postmill -d postmill \
        -tAc "SELECT COUNT(*) FROM forums" 2>/dev/null | tr -d '[:space:]' || echo 0)
    if (( forum_count > 0 )); then
        ok "PostgreSQL forum count = $forum_count (>0)"
    else
        fail "PostgreSQL forum count = $forum_count (expected >0)"
    fi

    submission_count=$(apptainer_exec psql -U postmill -d postmill \
        -tAc "SELECT COUNT(*) FROM submissions" 2>/dev/null | tr -d '[:space:]' || echo 0)
    if (( submission_count > 0 )); then
        ok "PostgreSQL submission count = $submission_count (>0)"
    else
        fail "PostgreSQL submission count = $submission_count (expected >0)"
    fi
fi

# ---- 4. HTTP smoke tests ---------------------------------------------
echo
echo "--- 4. HTTP endpoints ---"
# Homepage
http_check "Homepage"          "$BASE/"               2 "postmill\|AskReddit\|forum\|submissions\|front page\|hot"

# Login: Postmill issues a 302 cookie-check redirect before serving the form.
# Accept 2xx or 3xx.
login_code=$(curl -s -o /tmp/_reddit_test_body -w "%{http_code}" --max-time 15 \
    "$BASE/login" 2>/dev/null || echo "000")
if [[ "${login_code:0:1}" == "2" || "${login_code:0:1}" == "3" ]]; then
    ok "Login page → HTTP $login_code"
else
    fail "Login page → HTTP $login_code (wanted 2xx or 3xx)"
fi

# Registration: Postmill uses /registration (not /register)
http_check "Registration page"  "$BASE/registration"  2 "sign up\|register\|username\|password"

# Community pages — Postmill uses /f/<name> (not /+<name>).
# Communities confirmed present in this WebArena dataset.
for community in AskReddit DIY MachineLearning; do
    code=$(curl -s -o /tmp/_reddit_test_body -w "%{http_code}" --max-time 15 \
        "$BASE/f/$community" 2>/dev/null || echo "000")
    if [[ "${code:0:1}" == "2" || "${code:0:1}" == "3" ]]; then
        ok "Community /f/$community → HTTP $code"
    else
        fail "Community /f/$community → HTTP $code (wanted 2xx or 3xx)"
    fi
done

# Sort/filter pages
http_check "Hot posts"  "$BASE/?sort=hot" 2
http_check "New posts"  "$BASE/?sort=new" 2

# ---- 5. Login (form POST via /login_check with CSRF token) -----------
echo
echo "--- 5. Login ---"
# Step 1: GET /login with -L to follow the cookie-check redirect.
#   This sets the PHPSESSID cookie and returns the real login form with a CSRF token.
rm -f /tmp/_reddit_cookies
curl -s -c /tmp/_reddit_cookies -b /tmp/_reddit_cookies \
     -L --max-time 15 "$BASE/login" -o /tmp/_reddit_login_form 2>/dev/null || true

csrf_token=$(grep -o 'name="_csrf_token"[^>]*value="[^"]*"' /tmp/_reddit_login_form 2>/dev/null \
             | sed 's/.*value="//;s/"//' | head -1 || echo "")

if [[ -z "$csrf_token" ]]; then
    fail "Login CSRF token not found on /login page"
else
    ok "Login CSRF token obtained (${csrf_token:0:20}...)"

    # Step 2: POST credentials + CSRF token to /login_check WITHOUT -L.
    #   Success = 302 redirect to / (homepage).
    #   Failure = 302 redirect back to /login.
    #   (Using -L here causes curl to resubmit POST to /login on failure, which
    #    returns 405 Method Not Allowed — masking the real result.)
    login_location=$(curl -s \
        -c /tmp/_reddit_cookies -b /tmp/_reddit_cookies \
        --max-time 15 \
        -X POST "$BASE/login_check" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "_username=MarvelsGrantMan136" \
        --data-urlencode "_password=test1234" \
        --data-urlencode "_csrf_token=$csrf_token" \
        -D /tmp/_reddit_login_headers \
        -o /dev/null 2>/dev/null || echo "")

    login_http=$(grep "^HTTP" /tmp/_reddit_login_headers 2>/dev/null | tail -1 | awk '{print $2}' || echo "000")
    redir_to=$(grep -i "^Location:" /tmp/_reddit_login_headers 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo "")

    if [[ "$login_http" == "302" && "$redir_to" != *"/login"* ]]; then
        ok "Login → HTTP 302 redirect to $redir_to (credentials accepted)"
    elif [[ "$login_http" == "302" && "$redir_to" == *"/login"* ]]; then
        fail "Login → HTTP 302 but redirected back to /login (credentials rejected)"
    else
        fail "Login POST → HTTP $login_http (wanted 302 to /)"
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
