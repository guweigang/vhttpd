$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$lock = Get-Content (Join-Path $root 'scripts/ci/toolchain.env') -Raw | ConvertFrom-StringData
$toolchain = Join-Path $env:RUNNER_TEMP 'workbench-windows-toolchain'
if (Test-Path $toolchain) { throw 'Toolchain directory must be new' }
New-Item -ItemType Directory $toolchain | Out-Null
function Checkout-Pinned($url, $revision, $destination) {
 & git init -q $destination
 if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
 & git -C $destination config core.autocrlf false
 & git -C $destination remote add origin $url
 & git -C $destination fetch --depth 1 origin $revision
 if ($LASTEXITCODE -ne 0) { throw "fetch failed: $url" }
 & git -C $destination checkout -q --detach FETCH_HEAD
 if ($LASTEXITCODE -ne 0) { throw 'checkout failed' }
 if ((& git -C $destination rev-parse HEAD).Trim() -ne $revision) { throw 'Pinned revision mismatch' }
}
$v = Join-Path $toolchain 'v'
$sdk = Join-Path $toolchain 'vjsx'
Checkout-Pinned $lock.V_REPO $lock.V_COMMIT $v
Checkout-Pinned $lock.VC_REPO $lock.VC_COMMIT (Join-Path $v 'vc')
Checkout-Pinned $lock.VJSX_REPO $lock.VJSX_COMMIT $sdk
$quickjs = Join-Path $toolchain 'quickjs'
$quickjsCommit = (Get-Content (Join-Path $sdk '.quickjs-version') -Raw).Trim()
Checkout-Pinned 'https://github.com/quickjs-ng/quickjs' $quickjsCommit $quickjs
& bash ((Join-Path $sdk 'scripts/patch-quickjs.sh') -replace '\\','/') ($quickjs -replace '\\','/')
if ($LASTEXITCODE -ne 0) { throw 'QuickJS patch failed' }
$env:VFLAGS = '-cc msvc -gc boehm -d use_bundled_libgc'
Push-Location $v
try {
 & .\makev.bat -msvc -local
 if ($LASTEXITCODE -ne 0) { throw 'Native Windows V bootstrap failed' }
 & .\v.exe version
 if ($LASTEXITCODE -ne 0) { throw 'Native V unavailable' }
} finally { Pop-Location }
$qbuild = Join-Path $toolchain 'quickjs-build'
& cmake -S $quickjs -B $qbuild -G 'Visual Studio 17 2022' -A x64 -DQJS_BUILD_LIBC=ON -DBUILD_SHARED_LIBS=OFF
if ($LASTEXITCODE -ne 0) { throw 'QuickJS configure failed' }
& cmake --build $qbuild --config Release --target qjs_exe --parallel 2
if ($LASTEXITCODE -ne 0) { throw 'QuickJS build failed' }
$qlib = Get-ChildItem $qbuild -Filter qjs.lib -File -Recurse | Select-Object -First 1
$qexe = Get-ChildItem $qbuild -Filter qjs.exe -File -Recurse | Select-Object -First 1
if (!$qlib -or !$qexe) { throw 'QuickJS output missing' }
$result = (& $qexe.FullName -e 'print(1 + 1)' | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $result -ne '2') { throw 'QuickJS smoke failed' }
$ui2 = Join-Path $root '.deps/ui2'
Checkout-Pinned 'https://github.com/vlang/ui2' ((Get-Content (Join-Path $root 'desktop/ui2.commit') -Raw).Trim()) $ui2
$modules = Join-Path $toolchain 'modules'
& bash ((Join-Path $root 'desktop/prepare-ui2.sh') -replace '\\','/') ((Join-Path $modules 'ui2') -replace '\\','/')
if ($LASTEXITCODE -ne 0) { throw 'Build-local ui2 staging failed' }
Add-Content $env:GITHUB_PATH $v
Add-Content $env:GITHUB_ENV "VJSX_DIR=$sdk"
Add-Content $env:GITHUB_ENV "VJS_QUICKJS_PATH=$quickjs"
Add-Content $env:GITHUB_ENV "VJS_QUICKJS_LIB_PATH=$($qlib.FullName)"
Add-Content $env:GITHUB_ENV "WORKBENCH_WINDOWS_MODULES=$modules"
Add-Content $env:GITHUB_ENV "WORKBENCH_WINDOWS_SDK_PARENT=$toolchain"
Add-Content $env:GITHUB_ENV "VFLAGS=-cc msvc -gc boehm -d use_bundled_libgc"
New-Item -ItemType Directory -Force (Join-Path $root 'desktop/ci/results/windows-build') | Out-Null
Get-Content (Join-Path $root 'scripts/ci/toolchain.env') | Set-Content (Join-Path $root 'desktop/ci/results/windows-build/toolchain.txt')
Add-Content (Join-Path $root 'desktop/ci/results/windows-build/toolchain.txt') "QUICKJS_COMMIT=$quickjsCommit"
