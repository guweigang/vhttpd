#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/environment.sh"
export WCF_TEST_STATE="$wcf_root/state.json" WCF_TEST_PHASE=contract
wcf_start_server "$wcf_example/tests/cloud-entry.mts"
if ! "$wcf_vjsx" "$wcf_example/tests/e2e.mjs"; then tail -80 "$wcf_root/server.log" >&2; exit 1; fi
wcf_stop_server
export WCF_TEST_PHASE=persist
wcf_start_server "$wcf_example/app.mts"
if ! "$wcf_vjsx" "$wcf_example/tests/e2e.mjs"; then tail -80 "$wcf_root/server.log" >&2; exit 1; fi
echo 'All E2E checks passed (vjsx only).'
