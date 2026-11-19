#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
container="vhttpd-multi-paseo-test-$$"
docker run -d --name "$container" --label org.vhttpd.multi-paseo-test=true \
 -e MYSQL_ROOT_PASSWORD=multi-fixture-only -e MYSQL_DATABASE=multi_test \
 -e MYSQL_USER=multi_test -e MYSQL_PASSWORD=multi-fixture-only \
 -p 127.0.0.1::3306 mysql:8.0 >/dev/null
cleanup(){ result=$?; docker rm -fv "$container" >/dev/null; exit "$result"; }
trap cleanup EXIT
MULTI_APP_DB_CONTAINER="$container" python3 tests/multi-app-paseo/e2e.py
