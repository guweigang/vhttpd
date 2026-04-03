#!/bin/zsh

set -u

root_dir="${1:-$(pwd)}"
results_file=$(mktemp "${TMPDIR:-/tmp}/vhttpd_codexbot_profile.XXXXXX")
trap 'rm -f "$results_file"' EXIT

test_files=(
  "$root_dir/src/inproc_vjsx_executor_codexbot_core_test.v"
  "$root_dir/src/inproc_vjsx_executor_codexbot_lifecycle_test.v"
  "$root_dir/src/inproc_vjsx_executor_codexbot_projects_test.v"
  "$root_dir/src/inproc_vjsx_executor_codexbot_read_rpc_test.v"
  "$root_dir/src/inproc_vjsx_executor_codexbot_semantics_test.v"
  "$root_dir/src/inproc_vjsx_executor_codexbot_threads_test.v"
)

total_files=${#test_files[@]}
current_index=0

for test_file in "${test_files[@]}"; do
  current_index=$(( current_index + 1 ))
  printf "[%d/%d] %s\n" "$current_index" "$total_files" "$(basename "$test_file")" >&2
  timing_file=$(mktemp "${TMPDIR:-/tmp}/vhttpd_codexbot_time.XXXXXX")
  if /usr/bin/time -p v test "$test_file" >/dev/null 2>"$timing_file"; then
    result_status="ok"
  else
    result_status="fail"
  fi
  elapsed=$(awk '/^real / { print $2 }' "$timing_file")
  rm -f "$timing_file"
  printf "%s\t%s\t%s\n" "${elapsed:-0}" "$result_status" "$(basename "$test_file")" >> "$results_file"
done

printf "%-52s %-8s %s\n" "test file" "seconds" "status"
printf "%-52s %-8s %s\n" "---------" "-------" "------"
sort -t "$(printf '\t')" -k1,1nr "$results_file" | while IFS=$'\t' read -r elapsed result_status name; do
  printf "%-52s %-8s %s\n" "$name" "$elapsed" "$result_status"
done
