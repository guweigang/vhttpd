#!/usr/bin/env bash
# E2E smoke test for vhttpd — runs the binary with zero external deps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VHTTPD_BIN="${REPO_ROOT}/vhttpd"
PASS=0
FAIL=0

ok()  { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
ko()  { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }

if [[ ! -x "$VHTTPD_BIN" ]]; then
    echo "ERROR: binary not found: $VHTTPD_BIN"
    echo "Run 'make build' first."
    exit 1
fi

echo "=== vhttpd E2E Smoke Test ==="

echo ""
echo "1. --help returns usage"
if "$VHTTPD_BIN" --help >/dev/null 2>&1; then
    ok "--help exit 0"
else
    ko "--help did not exit 0"
fi

echo ""
echo "2. --version returns version string"
ver=$("$VHTTPD_BIN" --version 2>&1)
if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ok "--version returns semver-like: $ver"
else
    ko "--version returned unexpected: $ver"
fi

echo ""
echo "3. Unknown option returns non-zero"
if ! "$VHTTPD_BIN" --not-a-real-option >/dev/null 2>&1; then
    ok "unknown flag exits non-zero"
else
    ko "unknown flag should exit non-zero"
fi

echo ""
echo "4. Validate argument parsing rejects bad flags"
if ! "$VHTTPD_BIN" -1 >/dev/null 2>&1; then
    ok "short unknown flag exits non-zero"
else
    ko "short unknown flag should exit non-zero"
fi

echo ""
echo "=== Results ==="
echo "PASS: $PASS  FAIL: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
