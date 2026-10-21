param([string]$Destination = 'stage-b-portable')
$ErrorActionPreference = 'Stop'
if ($Destination -notmatch '^stage-[bcd]-[a-z0-9-]+$') { throw 'Use an isolated stage-b-*, stage-c-* or stage-d-* directory name.' }
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'flutter_app\build\windows\x64\runner\Release'
$output = Join-Path $root "environment\$Destination"
$library = Join-Path $root 'environment\stage-b-cargo\release\codex_timezone_core.dll'
if (!(Test-Path -LiteralPath $library)) { throw 'Build the Stage B Rust release DLL first.' }
New-Item -ItemType Directory -Force $output | Out-Null
# Copy runtime assets only, excluding local account/settings/context diagnostics.
foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
    $relative = [IO.Path]::GetRelativePath($source, $file.FullName).Replace('\','/')
    if ($relative -match '^[^/]+\.(exe|dll)$' -or $relative -eq 'native_assets.json' -or
        $relative -match '^data/(flutter_assets/|icudtl\.dat$|app\.so$)') {
        $target = Join-Path $output $relative
        New-Item -ItemType Directory -Force (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}
Copy-Item -LiteralPath $library -Destination (Join-Path $output 'codex_timezone_core.dll') -Force
Write-Output $output
