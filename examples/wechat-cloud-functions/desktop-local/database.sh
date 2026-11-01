#!/usr/bin/env bash
# Dedicated persistent loopback PostgreSQL for the Desktop project.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pg_tool() {
  local override=$1 tool=$2
  if [[ -n "$override" ]]; then printf '%s\n' "$override"
  elif command -v "$tool" >/dev/null; then command -v "$tool"
  else printf '%s\n' "/Applications/Postgres.app/Contents/Versions/latest/bin/$tool"; fi
}
pgctl=$(pg_tool "${WCF_PG_CTL:-}" pg_ctl)
data="$root/.runtime/postgres"
case "${1:-status}" in
  status) "$pgctl" -D "$data" status ;;
  stop) "$pgctl" -D "$data" -m fast -w stop ;;
  start)
    umask 077
    mkdir -p "$root/.runtime"
    if [[ ! -f "$data/PG_VERSION" ]]; then
      initdb=$(pg_tool "${WCF_INITDB:-}" initdb)
      "$initdb" -D "$data" -U wechat_desktop -A trust --encoding=UTF8 --no-locale
    fi
    if ! "$pgctl" -D "$data" status >/dev/null 2>&1; then
      "$pgctl" -D "$data" -l "$root/.runtime/postgres.log" -o '-h 127.0.0.1 -p 19896 -k /tmp' -w start
    fi
    psql=$(pg_tool "${WCF_PSQL:-}" psql)
    "$psql" -h 127.0.0.1 -p 19896 -U wechat_desktop -d postgres -v ON_ERROR_STOP=1 \
      -f "$root/../schema.sql" -f "$root/../schema-cloud-pgsql.sql"
    ;;
  *) echo 'Usage: database.sh start|stop|status' >&2; exit 1 ;;
esac
