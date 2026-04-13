#!/bin/bash
# test_shopping_admin.sh — smoke tests for the webarena_shopping_admin Apptainer instance.
# Run from any node where the instance is already up, or on the shopping_admin node itself.
# Usage: bash test_shopping_admin.sh [HOST] [PORT]
#   HOST defaults to localhost (or the value in homepage/.shopping_admin_node)
#   PORT defaults to 7780
#
# Exit code: 0 = all tests passed, 1 = one or more failures.

set -euo pipefail

# ---------- resolve host / port ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_FILE="$SCRIPT_DIR/../homepage/.shopping_admin_node"

if [[ -n "${1:-}" ]]; then
    HOST="$1"
elif [[ -f "$NODE_FILE" ]]; then
    HOST="$(cat "$NODE_FILE")"
else
    HOST="localhost"
fi
PORT="${2:-7780}"
BASE="http://$HOST:$PORT"
INST="webarena_shopping_admin"

# Detect whether we are on the server node (enables local apptainer/process checks)
LOCAL_NODE=$(hostname)
ON_SERVER_NODE=false
if [[ "$LOCAL_NODE" == "$HOST" ]]; then
    ON_SERVER_NODE=true
fi

PASS=0
FAIL=0
SKIP=0
admin_token=""  # fetched in section 8, used in sections 6+8

ok()   { echo "  PASS  $1"; (( ++PASS )); }
fail() { echo "  FAIL  $1"; (( ++FAIL )); }
skip() { echo "  SKIP  $1 (not on server node — run on $HOST to check)"; (( ++SKIP )); }

http_check() {
    # http_check LABEL URL [EXPECTED_CODE_PREFIX] [BODY_GREP]
    local label="$1" url="$2" want="${3:-2}" body_pat="${4:-}"
    local out code
    out=$(curl -s -o /tmp/_sadmin_test_body -w "%{http_code}" --max-time 15 "$url" 2>/dev/null || echo "000")
    code="$out"
    local first="${code:0:1}"
    if [[ "$first" != "$want" ]]; then
        fail "$label → HTTP $code (wanted ${want}xx)"
        return
    fi
    if [[ -n "$body_pat" ]] && ! grep -qi "$body_pat" /tmp/_sadmin_test_body 2>/dev/null; then
        fail "$label → HTTP $code but body missing '$body_pat'"
        return
    fi
    ok "$label → HTTP $code"
}

apptainer_exec() {
    apptainer exec instance://"$INST" "$@"
}

echo "=========================================="
echo "  WebArena Shopping Admin smoke tests"
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
for svc in cron elasticsearch mysqld nginx php-fpm redis-server; do
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

# ---- 3. MySQL connectivity & data ------------------------------------
echo
echo "--- 3. MySQL ---"
if ! $ON_SERVER_NODE; then
    skip "MySQL connectivity"
    skip "MySQL product count"
    skip "Magento base_url"
else
    if apptainer_exec mysql -h127.0.0.1 -umagentouser -pMyPassword \
            -e "SELECT 1" magentodb &>/dev/null 2>&1; then
        ok "MySQL accepts connections"
    else
        fail "MySQL not accepting connections"
    fi

    product_count=$(apptainer_exec mysql -h127.0.0.1 -umagentouser -pMyPassword \
        -sNe "SELECT COUNT(*) FROM catalog_product_entity" magentodb 2>/dev/null || echo 0)
    if (( product_count > 1000 )); then
        ok "MySQL product count = $product_count (>1k)"
    else
        fail "MySQL product count = $product_count (expected >1k)"
    fi

    base_url=$(apptainer_exec mysql -h127.0.0.1 -umagentouser -pMyPassword \
        -sNe "SELECT value FROM core_config_data WHERE path='web/unsecure/base_url' LIMIT 1" \
        magentodb 2>/dev/null || echo "UNKNOWN")
    if [[ "$base_url" == *"$HOST"* ]]; then
        ok "Magento base_url = $base_url"
    else
        fail "Magento base_url = '$base_url' (expected to contain $HOST)"
    fi
fi

# ---- 4. Redis --------------------------------------------------------
echo
echo "--- 4. Redis ---"
if ! $ON_SERVER_NODE; then
    skip "Redis"
else
    pong=$(apptainer_exec redis-cli ping 2>/dev/null || echo "FAIL")
    if [[ "$pong" == "PONG" ]]; then
        ok "Redis PONG"
    else
        fail "Redis ping → $pong"
    fi
fi

# ---- 5. Elasticsearch ------------------------------------------------
echo
echo "--- 5. Elasticsearch ---"
if ! $ON_SERVER_NODE; then
    skip "ES cluster health"
    skip "ES document count"
else
    es_status=$(apptainer_exec curl -s http://127.0.0.1:9200/_cluster/health 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])" 2>/dev/null || echo "unreachable")
    if [[ "$es_status" == "green" || "$es_status" == "yellow" ]]; then
        ok "ES cluster health = $es_status"
    else
        fail "ES cluster health = $es_status"
    fi

    es_docs=$(apptainer_exec curl -s http://127.0.0.1:9200/_cat/count?h=count 2>/dev/null \
        | tr -d ' \n' || echo 0)
    if (( es_docs > 100 )); then
        ok "ES document count = $es_docs (>100)"
    else
        fail "ES document count = $es_docs (expected >100)"
    fi
fi

# ---- 6. HTTP smoke tests ---------------------------------------------
echo
echo "--- 6. HTTP endpoints ---"
admin_code=$(curl -s -o /tmp/_sadmin_test_body -w "%{http_code}" --max-time 15 "$BASE/admin/" 2>/dev/null || echo "000")
if [[ "${admin_code:0:1}" == "2" || "${admin_code:0:1}" == "3" ]]; then
    ok "Admin root → HTTP $admin_code"
else
    fail "Admin root → HTTP $admin_code (wanted 2xx or 3xx)"
fi

http_check "Storefront homepage" "$BASE/"                                   2 "magento\|luma\|shopping"
http_check "Category page"       "$BASE/women.html"                         2
http_check "Search results"      "$BASE/catalogsearch/result/?q=shirt"      2
http_check "Cart page"           "$BASE/checkout/cart/"                     2

# ---- 7. REST API — guest cart ----------------------------------------
echo
echo "--- 7. REST API ---"
guest_cart=$(curl -s -o /tmp/_sadmin_cart -w "%{http_code}" --max-time 15 \
    -X POST "$BASE/rest/V1/guest-carts" \
    -H "Content-Type: application/json" 2>/dev/null || echo "000")
if [[ "${guest_cart:0:1}" == "2" ]]; then
    cart_id=$(cat /tmp/_sadmin_cart | tr -d '"' 2>/dev/null || echo "")
    ok "POST /rest/V1/guest-carts → $guest_cart (token: ${cart_id:0:16}...)"
else
    fail "POST /rest/V1/guest-carts → HTTP $guest_cart"
fi

# ---- 8. Admin REST API (token auth) ----------------------------------
echo
echo "--- 8. Admin REST API ---"
admin_token=$(curl -s --max-time 15 \
    -X POST "$BASE/rest/V1/integration/admin/token" \
    -H "Content-Type: application/json" \
    -d '{"username":"admin","password":"admin1234"}' 2>/dev/null | tr -d '"' || echo "")
if [[ -n "$admin_token" && ${#admin_token} -gt 10 && "$admin_token" != *"message"* ]]; then
    ok "Admin token obtained (${admin_token:0:16}...)"

    # REST store views requires admin auth on this dataset
    rest_sv_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
        "$BASE/rest/V1/store/storeViews" \
        -H "Authorization: Bearer $admin_token" 2>/dev/null || echo "000")
    if [[ "${rest_sv_code:0:1}" == "2" ]]; then
        ok "REST store views (authed) → HTTP $rest_sv_code"
    else
        fail "REST store views (authed) → HTTP $rest_sv_code"
    fi

    # Use the token to hit real admin-only endpoints.
    # --globoff required: curl treats [...] as ranges without it.
    admin_api_code=$(curl -s -o /dev/null -w "%{http_code}" --globoff --max-time 15 \
        "$BASE/rest/V1/customers/search?searchCriteria[pageSize]=1" \
        -H "Authorization: Bearer $admin_token" 2>/dev/null || echo "000")
    if [[ "${admin_api_code:0:1}" == "2" ]]; then
        ok "GET /rest/V1/customers/search → HTTP $admin_api_code"
    else
        fail "GET /rest/V1/customers/search → HTTP $admin_api_code"
    fi

    order_api_code=$(curl -s -o /dev/null -w "%{http_code}" --globoff --max-time 15 \
        "$BASE/rest/V1/orders?searchCriteria[pageSize]=1" \
        -H "Authorization: Bearer $admin_token" 2>/dev/null || echo "000")
    if [[ "${order_api_code:0:1}" == "2" ]]; then
        ok "GET /rest/V1/orders → HTTP $order_api_code"
    else
        fail "GET /rest/V1/orders → HTTP $order_api_code"
    fi
else
    fail "Admin token request failed (response: ${admin_token:0:80})"
fi

# ---- summary ---------------------------------------------------------
echo
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "=========================================="
(( FAIL == 0 ))
