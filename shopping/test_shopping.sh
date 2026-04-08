#!/bin/bash
# test_shopping.sh — smoke tests for the webarena_shopping Apptainer instance.
# Run from any node where the instance is already up, or on the shopping node itself.
# Usage: bash test_shopping.sh [HOST] [PORT]
#   HOST defaults to localhost (or the value in homepage/.shopping_node)
#   PORT defaults to 7770
#
# Exit code: 0 = all tests passed, 1 = one or more failures.

set -euo pipefail

# ---------- resolve host / port ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_FILE="$SCRIPT_DIR/../homepage/.shopping_node"

if [[ -n "${1:-}" ]]; then
    HOST="$1"
elif [[ -f "$NODE_FILE" ]]; then
    HOST="$(cat "$NODE_FILE")"
else
    HOST="localhost"
fi
PORT="${2:-7770}"
BASE="http://$HOST:$PORT"
INST="webarena_shopping"

PASS=0
FAIL=0

ok()   { echo "  PASS  $1"; (( ++PASS )); }
fail() { echo "  FAIL  $1"; (( ++FAIL )); }

http_check() {
    # http_check LABEL URL [EXPECTED_CODE] [BODY_GREP]
    local label="$1" url="$2" want="${3:-2}" body_pat="${4:-}"
    local out code
    out=$(curl -s -o /tmp/_shop_test_body -w "%{http_code}" --max-time 15 "$url" 2>/dev/null || echo "000")
    code="$out"
    local first="${code:0:1}"
    if [[ "$first" != "$want" ]]; then
        fail "$label → HTTP $code (wanted ${want}xx)"
        return
    fi
    if [[ -n "$body_pat" ]] && ! grep -qi "$body_pat" /tmp/_shop_test_body 2>/dev/null; then
        fail "$label → HTTP $code but body missing '$body_pat'"
        return
    fi
    ok "$label → HTTP $code"
}

apptainer_exec() {
    apptainer exec instance://"$INST" "$@"
}

echo "=========================================="
echo "  WebArena Shopping smoke tests"
echo "  Target : $BASE"
echo "  Instance: $INST"
echo "  $(date)"
echo "=========================================="

# ---- 1. Instance alive ------------------------------------------------
echo
echo "--- 1. Apptainer instance ---"
if apptainer instance list 2>/dev/null | grep -q "$INST"; then
    ok "instance $INST is listed"
else
    fail "instance $INST not found — is it running?"
fi

# ---- 2. Supervisor process status ------------------------------------
echo
echo "--- 2. Supervisord process status ---"
for svc in cron elasticsearch mysqld nginx php-fpm redis-server; do
    state=$(apptainer_exec supervisorctl status "$svc" 2>/dev/null | awk '{print $2}' || echo "ERROR")
    if [[ "$state" == "RUNNING" ]]; then
        ok "$svc RUNNING"
    else
        fail "$svc → $state"
    fi
done

# ---- 3. MySQL connectivity & data ------------------------------------
echo
echo "--- 3. MySQL ---"
if apptainer_exec mysql -h127.0.0.1 -umagentouser -pMyPassword \
        -e "SELECT 1" magentodb &>/dev/null 2>&1; then
    ok "MySQL accepts connections"
else
    fail "MySQL not accepting connections"
fi

product_count=$(apptainer_exec mysql -h127.0.0.1 -umagentouser -pMyPassword \
    -sNe "SELECT COUNT(*) FROM catalog_product_entity" magentodb 2>/dev/null || echo 0)
if (( product_count > 100000 )); then
    ok "MySQL product count = $product_count (>100k)"
else
    fail "MySQL product count = $product_count (expected >100k)"
fi

base_url=$(apptainer_exec mysql -h127.0.0.1 -umagentouser -pMyPassword \
    -sNe "SELECT value FROM core_config_data WHERE path='web/unsecure/base_url' LIMIT 1" \
    magentodb 2>/dev/null || echo "UNKNOWN")
if [[ "$base_url" == *"$HOST"* ]]; then
    ok "Magento base_url = $base_url"
else
    fail "Magento base_url = '$base_url' (expected to contain $HOST)"
fi

# ---- 4. Redis --------------------------------------------------------
echo
echo "--- 4. Redis ---"
pong=$(apptainer_exec redis-cli ping 2>/dev/null || echo "FAIL")
if [[ "$pong" == "PONG" ]]; then
    ok "Redis PONG"
else
    fail "Redis ping → $pong"
fi

# ---- 5. Elasticsearch ------------------------------------------------
echo
echo "--- 5. Elasticsearch ---"
es_status=$(apptainer_exec curl -s http://127.0.0.1:9200/_cluster/health 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])" 2>/dev/null || echo "unreachable")
if [[ "$es_status" == "green" || "$es_status" == "yellow" ]]; then
    ok "ES cluster health = $es_status"
else
    fail "ES cluster health = $es_status"
fi

es_docs=$(apptainer_exec curl -s http://127.0.0.1:9200/_cat/count?h=count 2>/dev/null \
    | tr -d ' \n' || echo 0)
if (( es_docs > 100000 )); then
    ok "ES document count = $es_docs (>100k)"
else
    fail "ES document count = $es_docs (expected >100k)"
fi

# ---- 6. HTTP smoke tests ---------------------------------------------
echo
echo "--- 6. HTTP endpoints ---"
http_check "Homepage"            "$BASE/"                          2 "magento\|luma\|shopping"
http_check "Category page"       "$BASE/women/tops-women.html"     2 "tops\|women\|product"
http_check "Search results"      "$BASE/catalogsearch/result/?q=shirt" 2 "shirt\|search\|result"
http_check "Product detail"      "$BASE/cassius-sparring-tank.html" 2
http_check "Cart page"           "$BASE/checkout/cart/"            2 "cart\|checkout"
http_check "Customer login"      "$BASE/customer/account/login/"   2 "login\|sign in"
http_check "Admin login"         "$BASE/admin/"                    2 "admin\|sign in\|login"
http_check "REST API ping"       "$BASE/rest/V1/store/storeViews"  2

# ---- 7. REST API — guest cart ----------------------------------------
echo
echo "--- 7. REST API ---"
guest_cart=$(curl -s -o /tmp/_shop_cart -w "%{http_code}" --max-time 15 \
    -X POST "$BASE/rest/V1/guest-carts" \
    -H "Content-Type: application/json" 2>/dev/null || echo "000")
if [[ "${guest_cart:0:1}" == "2" ]]; then
    cart_id=$(cat /tmp/_shop_cart | tr -d '"' 2>/dev/null || echo "")
    ok "POST /rest/V1/guest-carts → $guest_cart (token: ${cart_id:0:16}...)"
else
    fail "POST /rest/V1/guest-carts → HTTP $guest_cart"
fi

# ---- summary ---------------------------------------------------------
echo
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "=========================================="
(( FAIL == 0 ))
