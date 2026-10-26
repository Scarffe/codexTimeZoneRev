param([Parameter(Mandatory)][string]$OutputDirectory, [string]$CargoTargetDirectory=$env:CARGO_TARGET_DIR)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(!$CargoTargetDirectory){throw 'Build the Rust release helper first and provide CargoTargetDirectory.'}
$helper=Join-Path $CargoTargetDirectory 'release/codex_timezone_helper.exe'
if(!(Test-Path -LiteralPath $helper)){throw 'Missing Rust helper release executable.'}
$cmake=(Get-Command cmake.exe -ErrorAction SilentlyContinue).Source
if(!$cmake){$cmake='C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'}
if(!(Test-Path -LiteralPath $cmake)){throw 'CMake is required for the Windows runtime owner.'}
$build=Join-Path $root 'environment/runtime-owner-cmake'
& $cmake -S (Join-Path $root 'native/runtime_owner') -B $build -G 'Visual Studio 17 2022' -A x64 -DCTZ_BRIDGE_OWNED_TEST=OFF
if($LASTEXITCODE -ne 0){throw 'Runtime owner configuration failed.'}
& $cmake --build $build --config Release
if($LASTEXITCODE -ne 0){throw 'Runtime owner build failed.'}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$files=@(
  (Join-Path $build 'desktop_runtime_bridge/Release/codex_runtime_bridge.dll'),
  (Join-Path $build 'desktop_runtime_bridge/Release/codex_runtime_metadata.exe'),
  (Join-Path $build 'desktop_runtime_observer/Release/codex_desktop_observer.dll'),
  $helper)
foreach($file in $files){Copy-Item -LiteralPath $file -Destination $OutputDirectory -Force}
Write-Output 'Runtime owner companions built; no helper or Desktop process was started.'
