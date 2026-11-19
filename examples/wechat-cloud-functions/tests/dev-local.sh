#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/environment.sh"
wcf_start_server "$wcf_example/tests/local-entry.mjs"
if ! "$wcf_vjsx" "$wcf_example/tests/dev-local.mjs"; then
  tail -80 "$wcf_root/server.log" >&2; exit 1
fi
echo "Temporary PostgreSQL: $wcf_root"
if [[ "${WCF_SMOKE_ONLY:-0}" != 1 ]]; then
  echo 'Ctrl-C stops both services and removes the temporary database.'
  wait "$wcf_server_pid"
fi
