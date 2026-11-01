$ErrorActionPreference = 'Stop'
# Match vjsx's MSVC/vcpkg SDK contract: one SDK, both import-library spellings,
# and matching DLLs. Pin the ports repository so CI inputs stay reproducible.
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$revision = (Get-Content (Join-Path $PSScriptRoot 'windows-vcpkg.commit') -Raw).Trim()
$cache = Join-Path $root '.cache/vcpkg-binary-cache'
New-Item -ItemType Directory -Force $cache | Out-Null
$env:VCPKG_DEFAULT_BINARY_CACHE = $cache
$vcpkg = Join-Path $env:RUNNER_TEMP 'workbench-vcpkg'
& git init -q $vcpkg
& git -C $vcpkg remote add origin https://github.com/microsoft/vcpkg
& git -C $vcpkg fetch --depth 1 origin $revision
if ($LASTEXITCODE -ne 0) { throw 'Pinned vcpkg fetch failed' }
& git -C $vcpkg checkout -q --detach FETCH_HEAD
if ($LASTEXITCODE -ne 0) { throw 'Pinned vcpkg checkout failed' }
& (Join-Path $vcpkg 'bootstrap-vcpkg.bat') -disableMetrics
if ($LASTEXITCODE -ne 0) { throw 'vcpkg bootstrap failed' }
& (Join-Path $vcpkg 'vcpkg.exe') install openssl:x64-windows
if ($LASTEXITCODE -ne 0) { throw 'MSVC OpenSSL SDK build failed' }
$sdk = Join-Path $vcpkg 'installed/x64-windows'
$lib = Join-Path $sdk 'lib'
foreach ($name in @('crypto', 'ssl')) {
 $library = Get-ChildItem $lib -File -Recurse | Where-Object { $_.Name -in @("$name.lib", "lib$name.lib") } | Select-Object -First 1
 if (!$library) { throw "OpenSSL $name import library missing" }
 foreach ($alias in @("$name.lib", "lib$name.lib")) {
  $target = Join-Path $lib $alias
  if ($library.FullName -ne $target) { Copy-Item -Force $library.FullName $target }
 }
}
Add-Content $env:GITHUB_ENV "OPENSSL_ROOT_DIR=$sdk"
Add-Content $env:GITHUB_ENV "INCLUDE=$(Join-Path $sdk 'include');$env:INCLUDE"
Add-Content $env:GITHUB_ENV "LIB=$lib;$env:LIB"
Add-Content $env:GITHUB_ENV "LIBRARY_PATH=$lib;$env:LIBRARY_PATH"
Add-Content $env:GITHUB_ENV "PKG_CONFIG_LIBDIR=$(Join-Path $lib 'pkgconfig')"
Add-Content $env:GITHUB_ENV "PKG_CONFIG_PATH=$(Join-Path $lib 'pkgconfig')"
Add-Content $env:GITHUB_PATH (Join-Path $sdk 'bin')
Write-Host "MSVC OpenSSL SDK ready; vcpkg $revision"
