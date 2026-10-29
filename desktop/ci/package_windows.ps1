param([Parameter(Mandatory=$true)][string]$Executable, [string]$OutputDirectory = "$PSScriptRoot/results/windows-package")
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/../..").Path
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path $OutputDirectory).Path
$short = if ($env:GITHUB_SHA) { $env:GITHUB_SHA.Substring(0,12) } else { 'local' }
$name = "vhttpd-workbench-windows-amd64-test-$short"
$stage = Join-Path $OutputDirectory $name
if (Test-Path $stage) { throw 'Package staging directory must be new' }
New-Item -ItemType Directory -Force "$stage/resources", "$stage/tools/openssh", "$stage/licenses" | Out-Null
Copy-Item $Executable "$stage/vhttpd-workbench.exe"
Copy-Item "$root/admin/ui/brand/mark.png" "$stage/resources/vhttpd-mark.png"
foreach ($pattern in @('libcrypto-*.dll','libssl-*.dll')) {
 $dlls = @(Get-ChildItem "$env:OPENSSL_ROOT_DIR/bin" -Filter $pattern -File)
 if (!$dlls.Count) { throw "Missing OpenSSL DLL: $pattern" }
 $dlls | Copy-Item -Destination $stage
}
Copy-Item "$env:OPENSSL_ROOT_DIR/share/openssl/copyright" "$stage/licenses/OpenSSL.txt"
$pin = Get-Content "$PSScriptRoot/windows-openssh.json" -Raw | ConvertFrom-Json
$archive = Join-Path $OutputDirectory 'openssh-upstream.zip'
Invoke-WebRequest -Uri $pin.url -OutFile $archive
if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin.sha256) { throw 'OpenSSH upstream checksum mismatch' }
$sshStage = Join-Path $OutputDirectory 'openssh-upstream'
Expand-Archive $archive $sshStage
$ssh = Join-Path $sshStage 'OpenSSH-Win64'
# Client tools only: do not install or ship a server/service installer.
foreach ($file in @('ssh.exe','scp.exe','sftp.exe','ssh-keygen.exe','ssh-keyscan.exe','ssh-pkcs11-helper.exe','ssh-sk-helper.exe','libcrypto.dll','LICENSE.txt','NOTICE.txt')) {
 Copy-Item "$ssh/$file" "$stage/tools/openssh/$file"
}
$redistRoot = Join-Path $env:VCINSTALLDIR 'Redist/MSVC'
$crt = Get-ChildItem $redistRoot -Directory | Sort-Object Name -Descending | ForEach-Object {
 Join-Path $_.FullName 'x64/Microsoft.VC143.CRT'
} | Where-Object { Test-Path $_ } | Select-Object -First 1
if (!$crt) { throw 'App-local MSVC runtime directory missing' }
Get-ChildItem $crt -Filter '*.dll' -File | Copy-Item -Destination $stage
Get-ChildItem $crt -Filter '*.dll' -File | Copy-Item -Destination "$stage/tools/openssh"
if (!(Test-Path "$stage/vcruntime140.dll")) { throw 'App-local VC runtime missing' }
Copy-Item "$PSScriptRoot/WINDOWS-TESTING.txt" "$stage/README-Windows.txt"
# User-facing verifier runs in Windows PowerShell 5 as well as PowerShell 7.
@'
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$manifest = Get-Content (Join-Path $root 'files.json') -Raw | ConvertFrom-Json
foreach ($entry in $manifest) {
 $path = Join-Path $root $entry.path
 if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing: $($entry.path)" }
 if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) { throw "Checksum mismatch: $($entry.path)" }
}
Write-Host 'PASS: package files are complete and match SHA256.'
'@ | Set-Content "$stage/Verify-Package.ps1" -Encoding utf8
@{commit=$env:GITHUB_SHA; run=$env:GITHUB_RUN_ID; compiler='MSVC'; architecture='amd64'; channel='test'; openssh_tag=$pin.tag;
 v=(Get-Content "$root/scripts/ci/toolchain.env" | Select-String '^V_COMMIT=').ToString().Split('=')[1];
 ui2=(Get-Content "$root/desktop/ui2.commit" -Raw).Trim(); windows_vhttpd_runtime=$false} | ConvertTo-Json | Set-Content "$stage/build-info.json" -Encoding utf8
$files = @(Get-ChildItem $stage -File -Recurse | ForEach-Object {
 @{path=[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/');sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
} | Sort-Object { $_.path })
ConvertTo-Json -InputObject $files | Set-Content "$stage/files.json" -Encoding utf8
$zip = "$stage.zip"
Compress-Archive -Path $stage -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $name.zip" | Set-Content "$zip.sha256" -Encoding ascii
if ($env:GITHUB_OUTPUT) { "archive=$zip", "package_name=$name", "package_dir=$stage" | Add-Content $env:GITHUB_OUTPUT }
Write-Host "Packaged $name.zip ($([Math]::Round((Get-Item $zip).Length/1MB,1)) MB)"
