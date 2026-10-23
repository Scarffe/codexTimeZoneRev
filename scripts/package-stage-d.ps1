param([string]$Name = '', [ValidateSet('D','E','E34','F','G','H1','H2','I','I31','W','M1','L1','Sidebar')][string]$Stage = 'D')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$gitArguments = @('-c', "safe.directory=$($root.Replace('\','/'))", '-C', $root)
$commit = & git @gitArguments rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify source commit.' }
if (& git @gitArguments status --porcelain) { throw 'Commit changes before packaging a candidate.' }
$stageSuffix = if ($Stage -ne 'D') { "-$Stage" } else { '' }
if (!$Name) { $Name = "CodexTimeZone-DesktopMonitor$stageSuffix-windows-x64-rc-$($commit.Substring(0,7))" }
if ($Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,100}$') { throw 'Use a simple artifact name.' }
$artifacts = Join-Path $root 'environment\artifacts'
$output = Join-Path $artifacts $Name
$zip = "$output.zip"
if ((Test-Path -LiteralPath $output) -or (Test-Path -LiteralPath $zip)) { throw 'Candidate already exists; do not overwrite it.' }
if ($Stage -in @('L1','Sidebar') -and (Test-Path -LiteralPath "$zip.sha256")) { throw "$Stage checksum already exists; do not overwrite it." }
$source = Join-Path $root 'flutter_app\build\windows\x64\runner\Release'
$coreTarget = if ($Stage -in @('E34','F','G','H1','H2','I','I31')) { 'stage-e34-cargo' } else { 'stage-b-cargo' }
if ($Stage -eq 'H1') { $coreTarget = 'stage-h1-cargo' }
if ($Stage -eq 'H2') { $coreTarget = 'stage-h2-cargo' }
if ($Stage -eq 'I') { $coreTarget = 'stage-i-cargo' }
if ($Stage -eq 'I31') { $coreTarget = 'stage-i31-cargo' }
if ($Stage -eq 'W') { $coreTarget = 'stage-w-cargo' }
if ($Stage -eq 'M1') { $coreTarget = 'stage-m1-cargo' }
$library = Join-Path $root "environment\$coreTarget\release\codex_timezone_core.dll"
if ($Stage -in @('L1','Sidebar')) { $library = Join-Path $root 'environment\stage-l1-core\codex_timezone_core.dll' }
if ($Stage -in @('L1','Sidebar')) {
    $appVersion = if ($Stage -eq 'Sidebar') { '0.2.4-rc.8+12' } else { '0.2.4-rc.7+11' }
    if ((Get-Content -LiteralPath (Join-Path $root 'flutter_app\pubspec.yaml') -Raw) -notmatch ('(?m)^version: ' + [regex]::Escape($appVersion) + '\s*$')) { throw "$Stage requires version $appVersion." }
    if ($Stage -eq 'Sidebar' -and (Get-FileHash -LiteralPath $library).Hash -ne '11FEAD54EA59C219B3868DE65BB294BD46810CC6D349A72FCC5313A429AE12B8') { throw 'Sidebar requires the exact accepted L1 core hash.' }
    foreach ($required in @('THIRD_PARTY_NOTICES.md','licenses\AIPerf-Apache-2.0.txt','licenses\Win-CodexBar-MIT.txt','licenses\ccusage-MIT.txt')) {
        if (!(Test-Path -LiteralPath (Join-Path $root $required) -PathType Leaf)) { throw "Missing $Stage attribution input: $required" }
    }
}
foreach ($required in @((Join-Path $source 'codex_timezone.exe'),(Join-Path $source 'flutter_windows.dll'),(Join-Path $source 'data\app.so'),$library)) {
    if (!(Test-Path -LiteralPath $required)) { throw "Missing release input: $required" }
}
New-Item -ItemType Directory -Path $output -Force | Out-Null
foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
    $relative = [IO.Path]::GetRelativePath($source,$file.FullName).Replace('\','/')
    if ($relative -eq 'codex_timezone.exe' -or $relative -match '^[^/]+\.dll$' -or
        $relative -eq 'native_assets.json' -or $relative -match '^data/(flutter_assets/|icudtl\.dat$|app\.so$)') {
        $target = Join-Path $output $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
}
Copy-Item -LiteralPath $library -Destination (Join-Path $output 'codex_timezone_core.dll') -Force
foreach ($document in @('LICENSE',"STAGE-$Stage.md")) { Copy-Item -LiteralPath (Join-Path $root $document) -Destination $output }
if ($Stage -in @('M1','L1','Sidebar') -and (Test-Path -LiteralPath (Join-Path $root 'THIRD_PARTY_NOTICES.md'))) {
    Copy-Item -LiteralPath (Join-Path $root 'THIRD_PARTY_NOTICES.md') -Destination $output
    Copy-Item -LiteralPath (Join-Path $root 'licenses') -Destination $output -Recurse
}
Copy-Item -LiteralPath (Join-Path $root "release-notes\desktop-monitor$(if($Stage -ne 'D') { '-' + $Stage.ToLowerInvariant() })-rc.md") -Destination (Join-Path $output 'README.md')
@('@echo off','start "" "%~dp0codex_timezone.exe" --desktop-monitor') | Set-Content -LiteralPath (Join-Path $output 'Start-Monitor.cmd') -Encoding ascii
@('@echo off','start "" "%~dp0codex_timezone.exe" --desktop-monitor --monitor-exit') | Set-Content -LiteralPath (Join-Path $output 'Stop-Monitor.cmd') -Encoding ascii
if ($Stage -in @('H1','H2','I','I31')) {
    @('@echo off','start "" "%~dp0codex_timezone.exe" --desktop-monitor --isolated-instance') | Set-Content -LiteralPath (Join-Path $output 'Start-Trial.cmd') -Encoding ascii
    @('@echo off','start "" "%~dp0codex_timezone.exe" --desktop-monitor --isolated-instance --monitor-exit') | Set-Content -LiteralPath (Join-Path $output 'Stop-Trial.cmd') -Encoding ascii
}
if ($Stage -in @('W','M1','L1','Sidebar')) {
    @('@echo off','start "" "%~dp0codex_timezone.exe" --desktop-monitor --isolated-instance') | Set-Content -LiteralPath (Join-Path $output 'Start-Monitor.cmd') -Encoding ascii
    @('@echo off','start "" "%~dp0codex_timezone.exe" --desktop-monitor --isolated-instance --monitor-exit') | Set-Content -LiteralPath (Join-Path $output 'Stop-Monitor.cmd') -Encoding ascii
    @('@echo off','start "" "%~dp0codex_timezone.exe" --isolated-instance') | Set-Content -LiteralPath (Join-Path $output 'Start-Trial.cmd') -Encoding ascii
    @('@echo off','start "" "%~dp0codex_timezone.exe" --isolated-instance --monitor-exit') | Set-Content -LiteralPath (Join-Path $output 'Stop-Trial.cmd') -Encoding ascii
}
$buildInfo = @{stage=$Stage;kind='local-release-candidate';sourceCommit=$commit;platform='windows-x64';monitorIntervalSeconds=120;
    exeSha256=(Get-FileHash (Join-Path $output 'codex_timezone.exe')).Hash;
    coreSha256=(Get-FileHash (Join-Path $output 'codex_timezone_core.dll')).Hash;
    systemReplacementPerformed=$false;published=$false}
if ($Stage -eq 'L1') { $buildInfo.appVersion = '0.2.4-rc.7+11' }
if ($Stage -eq 'Sidebar') {
    $buildInfo.appVersion = '0.2.4-rc.8+12'
    $buildInfo.aotSha256 = (Get-FileHash -LiteralPath (Join-Path $output 'data/app.so')).Hash
}
$buildInfo | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'BUILD-INFO.json') -Encoding utf8
$manifest = @(Get-ChildItem -LiteralPath $output -Recurse -File | Sort-Object FullName | ForEach-Object {
    [ordered]@{path=[IO.Path]::GetRelativePath($output,$_.FullName).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
})
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'FILES-SHA256.json') -Encoding utf8
# Explicit inputs exclude settings, account data, logs and UI-test launchers.
if (Get-ChildItem -LiteralPath $output -Recurse -File | Where-Object Name -match '^(settings\.json|monitor-preferences.*|session-selection.*|pet-position.*|context.*|auth\.json)$|\.(log|pdb)$') {
    throw 'Private/runtime data appeared in candidate.'
}
[IO.Compression.ZipFile]::CreateFromDirectory($output,$zip)
$digest=(Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant()
"$digest  $Name.zip" | Set-Content -LiteralPath "$zip.sha256" -Encoding ascii
Write-Output $zip
Write-Output "SHA256: $digest"
