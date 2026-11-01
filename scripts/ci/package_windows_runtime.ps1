param([Parameter(Mandatory=$true)][string]$Executable, [string]$OutputDirectory = "$PSScriptRoot/../../tmp/ci/windows-package")
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/../..").Path
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$output = (Resolve-Path $OutputDirectory).Path
$name = 'vhttpd-windows-amd64'
$package = Join-Path $output $name
if (Test-Path $package) { throw 'Package directory must be new' }
New-Item -ItemType Directory $package | Out-Null
Copy-Item $Executable "$package/vhttpd.exe"
# Resolve the transitive PE dependency closure, with VC runtime app-local too.
$search = @((Split-Path $Executable), "$env:OPENSSL_ROOT_DIR/bin")
$pending = [Collections.Generic.Queue[string]]::new()
$pending.Enqueue("$package/vhttpd.exe")
$seen = @{}
$report = @()
while ($pending.Count) {
 $binary = $pending.Dequeue()
 $imports = & dumpbin /DEPENDENTS $binary
 if ($LASTEXITCODE -ne 0) { throw "Cannot inspect dependency closure: $binary" }
 foreach ($line in $imports) {
  if ($line -notmatch '^\s+([A-Za-z0-9_.+-]+\.dll)\s*$') { continue }
  $dll = $Matches[1]
  if ($seen.ContainsKey($dll)) { continue }
  $seen[$dll] = $true
  $report += "$(Split-Path $binary -Leaf) -> $dll"
  if ($dll -match '^(api-ms-win-|ext-ms-win-)') { continue }
  $candidate = $null
  foreach ($directory in $search) {
   $path = Join-Path $directory $dll
   if (Test-Path $path -PathType Leaf) { $candidate = $path; break }
  }
  if ($candidate) {
   Copy-Item $candidate "$package/$dll"
   $pending.Enqueue("$package/$dll")
  } elseif ($dll -match '^(vcruntime|msvcp|concrt|vcomp)\d' -or !(Test-Path "$env:WINDIR/System32/$dll")) {
   throw "Missing non-system dependency: $dll"
  }
 }
}
$report | Set-Content "$package/dependencies.txt"
New-Item -ItemType Directory "$package/admin", "$package/licenses" | Out-Null
Copy-Item "$root/admin/ui" "$package/admin/ui" -Recurse
Get-ChildItem "$env:OPENSSL_ROOT_DIR/share" -Filter copyright -File -Recurse | ForEach-Object {
 Copy-Item $_.FullName (Join-Path "$package/licenses" ($_.Directory.Name + '.txt'))
}
Copy-Item "$env:VJS_QUICKJS_PATH/LICENSE" "$package/licenses/QuickJS.txt"
Copy-Item "$root/scripts/ci/WINDOWS-RUNTIME.txt" "$package/README-Windows.txt"
$buildInfo = (& $Executable --build-info | Out-String) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $buildInfo.gc -ne 'boehm' -or !$buildInfo.gc_enabled) { throw 'Actual runtime has no active Boehm GC' }
$lock = Get-Content "$root/scripts/ci/toolchain.env" -Raw | ConvertFrom-StringData
@{platform='windows-amd64'; source_commit=$env:GITHUB_SHA; build_info=$buildInfo; v_commit=$lock.V_COMMIT;
 vjsx_commit=$lock.VJSX_COMMIT; run_id=$env:GITHUB_RUN_ID; compiler='MSVC'} | ConvertTo-Json -Depth 8 | Set-Content "$package/runtime-manifest.json" -Encoding utf8
$zip = "$package.zip"
Compress-Archive -Path $package -DestinationPath $zip
"$((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant())  $name.zip" | Set-Content "$zip.sha256" -Encoding ascii
if ($env:GITHUB_OUTPUT) { "archive=$zip" | Add-Content $env:GITHUB_OUTPUT }
Write-Host "Packaged $name.zip; runtime $($buildInfo.version)"
