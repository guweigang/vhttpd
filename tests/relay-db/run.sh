#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
# Usage: VHTTPD_BIN=/path/to/new/vhttpd VJSX_BIN=/path/to/vjsx bash tests/relay-db/run.sh
# Only this disposable MySQL container is created or removed. The JS application
# runs in vhttpd's embedded vjsx; Python only supervises processes and assertions.
container="vhttpd-relay-db-test-$$"
docker run -d --name "$container" --label org.vhttpd.relay-db-test=true \
  -e MYSQL_ROOT_PASSWORD=relay-fixture-only -e MYSQL_DATABASE=relay_test \
  -e MYSQL_USER=relay_test -e MYSQL_PASSWORD=relay-test-only \
  -p 127.0.0.1::3306 mysql:8.0 --max-allowed-packet=16777216 \
  --transaction-isolation=READ-COMMITTED >/dev/null
cleanup() {
  result=$?
  if [ "$result" -ne 0 ]; then docker logs "$container" >&2 || true; fi
  docker rm -f "$container" >/dev/null
}
trap cleanup EXIT
RELAY_DB_TEST_CONTAINER="$container" python3 tests/relay-db/e2e.py
"${VJSX_BIN:-vjsx}" --runtime node tests/relay-db/desktop-draft.mjs
