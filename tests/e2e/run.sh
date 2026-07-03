#!/usr/bin/env bash
# Entry point for running all e2e tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== vhttpd E2E Test Suite ==="
echo ""

bash "${SCRIPT_DIR}/smoke_test.sh"
bash "${SCRIPT_DIR}/config_acceptance_test.sh"

echo ""
echo "=== All E2E tests passed ==="
