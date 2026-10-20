param([string]$CMake = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (!$CMake) {
    $command = Get-Command cmake -ErrorAction SilentlyContinue
    if ($command) { $CMake = $command.Source }
    else {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (!$vs) { throw 'Visual Studio C++ build tools not found.' }
        $CMake = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    }
}
$build = Join-Path $root 'environment\desktop-prototype'
& $CMake -S (Join-Path $PSScriptRoot 'desktop-prototype') -B $build -G 'Visual Studio 17 2022' -A x64
if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed.' }
& $CMake --build $build --config Release
if ($LASTEXITCODE -ne 0) { throw 'Prototype build failed.' }
Write-Output (Join-Path $build 'Release\desktop_prototype.exe')
