#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
container="vhttpd-relay-takeover-test-$$"
docker run -d --name "$container" --label org.vhttpd.relay-takeover-test=true \
  -e MYSQL_ROOT_PASSWORD=relay-fixture-only -e MYSQL_DATABASE=relay_test \
  -e MYSQL_USER=relay_test -e MYSQL_PASSWORD=relay-test-only \
  -p 127.0.0.1::3306 mysql:8.0 --transaction-isolation=READ-COMMITTED >/dev/null
cleanup() {
  result=$?
  if [ "$result" -ne 0 ]; then docker logs "$container" >&2 || true; fi
  docker rm -fv "$container" >/dev/null
}
trap cleanup EXIT
RELAY_DB_TEST_CONTAINER="$container" python3 tests/relay-takeover/e2e.py
