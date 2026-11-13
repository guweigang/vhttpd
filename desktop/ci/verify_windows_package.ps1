param([Parameter(Mandatory=$true)][string]$Archive, [Parameter(Mandatory=$true)][string]$ResultDirectory)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $ResultDirectory | Out-Null
$ResultDirectory = (Resolve-Path $ResultDirectory).Path
$expected = (Get-Content "$Archive.sha256" -Raw).Split(' ',[StringSplitOptions]::RemoveEmptyEntries)[0].Trim()
if ((Get-FileHash $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Archive SHA256 mismatch' }
$extract = Join-Path $env:RUNNER_TEMP 'Windows 用户测试 package with spaces'
New-Item -ItemType Directory -Force $extract | Out-Null
Expand-Archive $Archive $extract
$package = (Get-ChildItem $extract -Directory | Select-Object -First 1).FullName
& "$package/Verify-Package.ps1"
$metadata = Get-Content "$package/build-info.json" -Raw | ConvertFrom-Json
$hostExe = Join-Path $package 'vhttpd-workbench.exe'
if ((Get-Item $hostExe).VersionInfo.ProductVersion -ne $metadata.version) { throw 'Desktop executable and package version disagree' }
if ((Get-Content "$package/VERSION.txt" -Raw).Trim() -ne "Desktop $($metadata.version)") { throw 'Desktop VERSION.txt disagrees with package metadata' }
$versionOutput = Join-Path $ResultDirectory 'desktop-version.txt'
$versionProcess = Start-Process $hostExe -ArgumentList '--version' -PassThru -RedirectStandardOutput $versionOutput
try {
 if (!$versionProcess.WaitForExit(10000) -or $versionProcess.ExitCode -ne 0) { throw 'Desktop --version failed' }
} finally { if (!$versionProcess.HasExited) { Stop-Process -Id $versionProcess.Id -Force } }
if (([string](Get-Content $versionOutput -Raw)).Trim() -ne "vhttpd Desktop $($metadata.version)") { throw 'Desktop CLI and package version disagree' }
# Inspect every executable and DLL, not only the host's direct imports.
$report = @()
foreach ($binary in (Get-ChildItem $package -File -Recurse | Where-Object { $_.Extension -in @('.exe','.dll') })) {
 $dependencies = & dumpbin /DEPENDENTS $binary.FullName
 if ($LASTEXITCODE -ne 0) { throw "Cannot inspect PE dependencies: $($binary.Name)" }
 foreach ($line in $dependencies) {
  if ($line -notmatch '^\s+([A-Za-z0-9_.+-]+\.dll)\s*$') { continue }
  $name = $Matches[1]
  $local = Join-Path $binary.DirectoryName $name
  $root = Join-Path $package $name
  $system = Join-Path "$env:WINDIR/System32" $name
  $vcRuntime = $name -match '^(vcruntime|msvcp|concrt|vcomp)\d'
  if ($vcRuntime -and !(Test-Path $local) -and !(Test-Path $root)) { throw "VC runtime is not bundled: $name" }
  if (!(Test-Path $local) -and !(Test-Path $root) -and $name -notmatch '^(api-ms-win-|ext-ms-win-)' -and !(Test-Path $system)) { throw "Non-system dependency missing: $($binary.Name) -> $name" }
  $report += "$($binary.Name) -> $name"
 }
}
$report | Set-Content "$ResultDirectory/dependencies.txt"
# Restrict lookup to the app and Windows itself. No compiler, Git, Node, SDK,
# system OpenSSH or source checkout belongs to the application's runtime PATH.
$fixturePython = (Get-Command python -CommandType Application).Source
$env:PATH = "$package;$env:WINDIR/System32;$env:WINDIR"
$env:VHTTPD_DESKTOP_DATA_DIR = "$ResultDirectory/isolated-data"
$env:VHTTPD_DESKTOP_REGISTRY = "$ResultDirectory/isolated-data/projects.json"
$env:XDG_CACHE_HOME = "$ResultDirectory/font-cache"
foreach ($attempt in 0..2) {
 if ($attempt -eq 1) {
  $cached = @(Get-ChildItem $env:XDG_CACHE_HOME -Filter '*.ttf' -Recurse -File)
  if ($cached.Count -ne 2) { throw 'Regular/bold font cache missing' }
  [IO.File]::WriteAllText($cached[0].FullName, 'corrupt cache fixture')
 }
 $fonts = Start-Process "$package/vhttpd-workbench.exe" -WorkingDirectory $extract -ArgumentList '--font-smoke' -PassThru -RedirectStandardOutput "$ResultDirectory/font-$attempt.log" -RedirectStandardError "$ResultDirectory/font-$attempt-stderr.log"
 if (!$fonts.WaitForExit(60000) -or $fonts.ExitCode -ne 0) {
  if (!$fonts.HasExited) { Stop-Process $fonts.Id -Force }
  throw "Packaged font smoke failed; see font-$attempt-stderr.log"
 }
}
if ($env:VHTTPD_RUNTIME_TEST_TAG) {
 $runtime = Start-Process $hostExe -WorkingDirectory $extract -ArgumentList '--runtime-smoke' -PassThru -RedirectStandardOutput "$ResultDirectory/runtime-download.log" -RedirectStandardError "$ResultDirectory/runtime-download-stderr.log"
 try {
  if (!$runtime.WaitForExit(240000) -or $runtime.ExitCode -ne 0) {
   throw 'Public Windows runtime download/installation failed; see runtime-download logs'
  }
 } finally { if (!$runtime.HasExited) { Stop-Process $runtime.Id -Force } }
}
# The server fixture is a CI tool only. All client operations use the actual
# extracted Desktop and bundled ssh.exe under the restricted runtime PATH.
$python = $fixturePython
$metadata = "$ResultDirectory/ssh-fixture.json"
$fixture = Start-Process $python -ArgumentList @("$PSScriptRoot/windows_ssh_fixture.py", $metadata) -PassThru -RedirectStandardOutput "$ResultDirectory/ssh-fixture.log" -RedirectStandardError "$ResultDirectory/ssh-fixture-stderr.log"
try {
 $deadline = (Get-Date).AddSeconds(20)
 while (!(Test-Path $metadata) -and !$fixture.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; $fixture.Refresh() }
 if (!(Test-Path $metadata)) { throw 'Loopback SSH fixture did not start' }
 $info = Get-Content $metadata -Raw | ConvertFrom-Json
 $env:VHTTPD_WINDOWS_SSH_FIXTURE_PORT = $info.port
 $env:VHTTPD_WINDOWS_SSH_FIXTURE_HTTP_PORT = $info.http_port
 $env:VHTTPD_WINDOWS_SSH_FIXTURE_FINGERPRINT = $info.fingerprint
 $env:VHTTPD_WINDOWS_SMOKE_RESULT = "$ResultDirectory/ssh-smoke-result.txt"
 $env:VHTTPD_WINDOWS_SMOKE_LOG = "$ResultDirectory/ssh-native-check.log"
 $smoke = Start-Process "$package/vhttpd-workbench.exe" -WorkingDirectory $extract -ArgumentList '--windows-ssh-smoke' -PassThru -RedirectStandardOutput "$ResultDirectory/ssh-helper.log" -RedirectStandardError "$ResultDirectory/ssh-helper-stderr.log"
 try {
  if (!$smoke.WaitForExit(60000)) { throw 'Packaged SSH helper smoke timed out' }
  if ($smoke.ExitCode -ne 0 -or !(Test-Path $env:VHTTPD_WINDOWS_SMOKE_RESULT) -or (Get-Content $env:VHTTPD_WINDOWS_SMOKE_RESULT -Raw) -ne 'PASS') { throw "Packaged SSH smoke failed (exit $($smoke.ExitCode)); see ssh-smoke-result.txt" }
 } finally { if (!$smoke.HasExited) { Stop-Process -Id $smoke.Id -Force } }
} finally {
 if (!$fixture.HasExited) { Stop-Process -Id $fixture.Id -Force }
 Remove-Item Env:VHTTPD_WINDOWS_SSH_FIXTURE_PORT, Env:VHTTPD_WINDOWS_SSH_FIXTURE_HTTP_PORT, Env:VHTTPD_WINDOWS_SSH_FIXTURE_FINGERPRINT -ErrorAction SilentlyContinue
}
$ssh = Start-Process "$package/tools/openssh/ssh.exe" -ArgumentList '-V' -PassThru -RedirectStandardOutput "$ResultDirectory/ssh-version.log" -RedirectStandardError "$ResultDirectory/ssh-version-stderr.log"
if (!$ssh.WaitForExit(10000) -or $ssh.ExitCode -ne 0) { if (!$ssh.HasExited) { Stop-Process $ssh.Id -Force }; throw 'Bundled OpenSSH did not run' }
$env:VHTTPD_DESKTOP_CI_READY = "$ResultDirectory/packaged-window-ready.txt"
$process = Start-Process "$package/vhttpd-workbench.exe" -WorkingDirectory $extract -PassThru -RedirectStandardOutput "$ResultDirectory/packaged-stdout.log" -RedirectStandardError "$ResultDirectory/packaged-stderr.log"
try {
 $deadline = (Get-Date).AddSeconds(30)
 while (!(Test-Path $env:VHTTPD_DESKTOP_CI_READY) -and !$process.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; $process.Refresh() }
 if (!(Test-Path $env:VHTTPD_DESKTOP_CI_READY)) { throw 'Extracted Desktop window did not start' }
 Start-Sleep -Seconds 2
 $process.Refresh()
 if ($process.HasExited) { throw 'Extracted Desktop exited unexpectedly' }
 if (!$process.CloseMainWindow() -or !$process.WaitForExit(15000) -or $process.ExitCode -ne 0) { throw 'Extracted Desktop did not exit normally' }
} finally { if (!$process.HasExited) { Stop-Process -Id $process.Id -Force } }
@{archive_sha256=$expected; startup='passed'; normal_exit='passed'; dependency_closure='passed'; bundled_ssh='passed'; native_ssh_password_and_forwarding='passed'; packaged_password_helper='passed'; development_path=$false; real_server_acceptance='pending user Windows test'} | ConvertTo-Json | Set-Content "$ResultDirectory/package-acceptance.json"
