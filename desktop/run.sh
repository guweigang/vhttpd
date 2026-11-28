#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/desktop/build.sh"
exec "$root/desktop/bin/vhttpd-workbench.app/Contents/MacOS/vhttpd-workbench" "$@"
