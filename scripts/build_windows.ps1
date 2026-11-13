param([string]$OutputDirectory = "$PSScriptRoot/../tmp/ci/windows-runtime")
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/..").Path
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$output = (Resolve-Path $OutputDirectory).Path
if (!$env:VJSX_DIR -or !$env:VJS_QUICKJS_LIB_PATH -or !$env:OPENSSL_ROOT_DIR) {
 throw 'Prepare the pinned MSVC V/QuickJS and OpenSSL/database SDK before building.'
}
$stage = Join-Path $output 'src'
if (Test-Path $stage) { throw 'Build source staging directory must be new' }
# Identical exclusions to Makefile prepare-build-src; no test helpers enter prod.
python -c "import shutil,sys; shutil.copytree(sys.argv[1],sys.argv[2],ignore=shutil.ignore_patterns('*_test.v','*_test_support.v','test_*.v','inproc_vjsx_executor_codexbot_helpers.v'))" "$root/src" $stage
if ($LASTEXITCODE -ne 0) { throw 'Runtime source staging failed' }
# Preserve the module manifest for @VMOD_FILE, even outside the repository.
Copy-Item "$root/v.mod" "$output/v.mod"
New-Item -ItemType Directory -Force "$output/admin" | Out-Null
Copy-Item "$root/admin/ui" "$output/admin/ui" -Recurse
# Native headers use @VMODROOT/src; stage at the same relative path.
$path = "$stage|$(Split-Path $env:VJSX_DIR)|@vlib|@vmodules"
& v -prod -new-compiler -nocache -cc msvc -gc boehm -d link_quickjs -d use_openssl -d enable_db -w -enable-globals `
 -path $path -o "$output/vhttpd.exe" $stage 2>&1 | Tee-Object "$output/build.log"
if ($LASTEXITCODE -ne 0) { throw 'MSVC vhttpd production build failed' }
# Copy SDK DLLs to probe the real build before resolving the package closure.
Get-ChildItem "$env:OPENSSL_ROOT_DIR/bin" -Filter '*.dll' -File | Copy-Item -Destination $output
$redist = Join-Path $env:VCINSTALLDIR 'Redist/MSVC'
$crt = Get-ChildItem $redist -Directory | Sort-Object Name -Descending | ForEach-Object {
 Join-Path $_.FullName 'x64/Microsoft.VC143.CRT'
} | Where-Object { Test-Path $_ } | Select-Object -First 1
if (!$crt) { throw 'MSVC runtime redistributable directory missing' }
Get-ChildItem $crt -Filter '*.dll' -File | Copy-Item -Destination $output
python "$root/scripts/ci/verify_gc_runtime.py" "$output/vhttpd.exe"
if ($LASTEXITCODE -ne 0) { throw 'Built runtime has no active Boehm GC' }
if ($env:GITHUB_OUTPUT) { "executable=$output/vhttpd.exe", "output_directory=$output" | Add-Content $env:GITHUB_OUTPUT }
