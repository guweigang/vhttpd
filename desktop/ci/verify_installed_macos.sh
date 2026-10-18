#!/bin/bash
# Test the distributed app on the actual target OS using only macOS tools.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
if [[ $# != 3 ]]; then
  echo 'Usage: verify_installed_macos.sh ARCHIVE EXPECTED_OS_MAJOR EXPECTED_SHA256' >&2
  exit 2
fi
archive="$1"
expected="$2"
checksum="$3"
case "$expected" in 15|26) ;; *) echo 'Expected OS must be 15 or 26.' >&2; exit 2;; esac
actual="$(/usr/bin/sw_vers -productVersion)"
if [[ "${actual%%.*}" != "$expected" ]]; then
  echo "BLOCKED: expected macOS $expected, actual macOS $actual; no target-system result recorded." >&2
  exit 2
fi
if [[ "$(/usr/bin/uname -m)" != arm64 ]]; then
  echo 'BLOCKED: this release requires an arm64 runner.' >&2
  exit 2
fi
actual_checksum="$(/usr/bin/shasum -a 256 "$archive")"
actual_checksum="${actual_checksum%% *}"
if [[ "$actual_checksum" != "$checksum" ]]; then
  echo 'FAIL: archive SHA256 does not match the release under test.' >&2
  exit 1
fi
original_home="$HOME"
report="$(/usr/bin/mktemp -d /private/tmp/vhttpd-macos-runtime.XXXXXX)"
report="$(cd "$report" && pwd -P)"
echo "Evidence directory: $report"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "report=$report" >> "$GITHUB_OUTPUT"
fi
{
  /usr/bin/sw_vers
  /usr/bin/uname -m
  echo "archive_sha256=$checksum"
  echo 'coverage=archive extraction, bundle relocation, native host manager and runtime, HTTP, cross-include publication/restart/effectiveness/history'
  echo 'not_covered=Finder opening, GUI controls, browser interaction, Gatekeeper download approval'
} > "$report/environment.txt"
record_result() {
  local result="$1"
  if [[ "$result" == 0 ]]; then
    echo PASS > "$report/result.txt"
  else
    echo "FAIL exit=$result" > "$report/result.txt"
  fi
  echo "Evidence retained: $report"
}
trap 'record_result "$?"' EXIT
/bin/mkdir -p "$report/Extracted" "$report/Applications with spaces" "$report/Fresh Home" "$report/tmp"
/usr/bin/ditto -x -k "$archive" "$report/Extracted"
[[ -s "$report/Extracted/安装说明.txt" ]]
# Install the complete bundle into a separate directory; run outside the checkout.
/usr/bin/ditto "$report/Extracted/vhttpd-workbench.app" "$report/Applications with spaces/vhttpd-workbench.app"
app="$report/Applications with spaces/vhttpd-workbench.app"
/usr/bin/codesign --verify --deep --strict "$app" > "$report/signature.txt" 2>&1
minimum="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$app/Contents/Info.plist")"
[[ "$minimum" == 15.0 ]]
/usr/bin/file "$app/Contents/MacOS/vhttpd-workbench" "$app/Contents/Resources/runtime/vhttpd" > "$report/binaries.txt"
# Record policy assessment separately. CI is not a downloaded Finder first-open test.
/usr/sbin/spctl --assess --type execute --verbose=4 "$app" > "$report/gatekeeper.txt" 2>&1 || true
/bin/cat > "$report/no-development.sb" <<'SB'
(version 1)
(allow default)
(deny file-read* (subpath "/opt/homebrew") (subpath "/usr/local") (subpath (param "CHECKOUT")) (subpath (param "ORIGINAL_HOME")))
(deny process-exec (subpath "/Applications/Xcode.app") (subpath "/Library/Developer") (literal "/usr/bin/cc") (literal "/usr/bin/clang") (literal "/usr/bin/xcrun") (literal "/usr/bin/python3"))
SB
checkout="$(cd "$(/usr/bin/dirname "$0")/../.." && pwd -P)"
cd "$report"
for mode in --smoke --persistent-status-smoke; do
  log="$report/${mode#--}.log"
  /usr/bin/env -i HOME="$report/Fresh Home" TMPDIR="$report/tmp/" PATH="$PATH" LANG=en_US.UTF-8 \
    /usr/bin/sandbox-exec -D "CHECKOUT=$checkout" -D "ORIGINAL_HOME=$original_home" -f "$report/no-development.sb" \
    "$app/Contents/MacOS/vhttpd-workbench" "$mode" > "$log" 2>&1
  /bin/cat "$log"
done
echo "PASS macOS $actual arm64: same release zip, extracted + relocated, fresh HOME, denied development trees and compiler execution"
