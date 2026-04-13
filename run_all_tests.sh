#!/bin/bash
# run_all_tests.sh — Run smoke tests for all WebArena services.
#
# Reads node hostnames from homepage/.<svc>_node files (written by each
# run_*.sh script after its service is healthy). Runs each service's test
# script with the correct host, then prints a final summary.
#
# All test scripts support remote-node execution: apptainer/process checks
# are skipped automatically when run from a different node. Only the HTTP
# and API checks run — which is exactly what this script tests.
#
# Usage (from webarena_build/):
#   bash run_all_tests.sh
#
# Exit code: 0 = all services passed, 1 = one or more failures.

set -uo pipefail

BUILDDIR="$(cd "$(dirname "$0")" && pwd)"
NODEDIR="$BUILDDIR/homepage"

PASS_SVCS=()
FAIL_SVCS=()
SKIP_SVCS=()

run_service_test() {
    local svc="$1"        # e.g. "shopping"
    local script="$2"     # full path to test_*.sh

    # Resolve HOST from .node file (each test script also does this, but we
    # print it in the summary header, so read it here too).
    local host
    if [[ -f "$NODEDIR/.${svc}_node" ]]; then
        host=$(cat "$NODEDIR/.${svc}_node")
    else
        host="(no node file)"
    fi

    echo ""
    echo "##################################################"
    echo "## $svc  →  $host"
    echo "##################################################"

    if [[ ! -f "$script" ]]; then
        echo "  SKIP  test script not found: $script"
        SKIP_SVCS+=("$svc")
        return
    fi

    if [[ "$host" == "(no node file)" ]]; then
        echo "  FAIL  homepage/.$svc_node not found — service may not be running"
        FAIL_SVCS+=("$svc")
        return
    fi

    # Run the test script; capture exit code without letting set -e abort us
    if bash "$script" "$host"; then
        PASS_SVCS+=("$svc")
    else
        FAIL_SVCS+=("$svc")
    fi
}

echo "=========================================="
echo "  WebArena — all-services smoke test"
echo "  Running on: $(hostname)"
echo "  $(date)"
echo "=========================================="

run_service_test "shopping"       "$BUILDDIR/shopping/test_shopping.sh"
run_service_test "shopping_admin" "$BUILDDIR/shopping_admin/test_shopping_admin.sh"
run_service_test "reddit"         "$BUILDDIR/reddit/test_reddit.sh"
run_service_test "gitlab"         "$BUILDDIR/gitlab/test_gitlab.sh"
run_service_test "wikipedia"      "$BUILDDIR/wikipedia/test_wikipedia.sh"

echo ""
echo "##################################################"
echo "## FINAL SUMMARY"
echo "##################################################"
echo "  PASSED (${#PASS_SVCS[@]}): ${PASS_SVCS[*]:-none}"
echo "  FAILED (${#FAIL_SVCS[@]}): ${FAIL_SVCS[*]:-none}"
echo "  SKIPPED (${#SKIP_SVCS[@]}): ${SKIP_SVCS[*]:-none}"
echo ""

if (( ${#FAIL_SVCS[@]} == 0 )); then
    echo "  All services passed."
    exit 0
else
    echo "  One or more services FAILED."
    exit 1
fi
