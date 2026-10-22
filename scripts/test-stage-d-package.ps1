param([Parameter(Mandatory)][string]$Archive, [ValidateSet('D','E','E34','F','G','H1','H2','I','I31')][string]$Stage='D')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$Archive = (Resolve-Path -LiteralPath $Archive).Path
$checksum = (Get-Content -LiteralPath "$Archive.sha256" -Raw).Trim() -split '\s+',2
if ($checksum.Count -ne 2 -or $checksum[1] -ne [IO.Path]::GetFileName($Archive) -or
    (Get-FileHash -LiteralPath $Archive).Hash -ne $checksum[0]) { throw 'Archive SHA256 mismatch.' }
$output = Join-Path $root "environment\stage-$($Stage.ToLowerInvariant())-smoke-$([Guid]::NewGuid().ToString('N'))"
$prefix = [IO.Path]::GetFullPath($output)+[IO.Path]::DirectorySeparatorChar
$zip = [IO.Compression.ZipFile]::OpenRead($Archive)
try {
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $zip.Entries) {
        $name=$entry.FullName.Replace('\','/')
        $target=[IO.Path]::GetFullPath((Join-Path $output $name))
        if ([IO.Path]::IsPathRooted($name) -or $name.Split('/') -contains '..' -or
            !$target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or !$names.Add($name)) {
            throw "Unsafe or duplicate ZIP entry: $name"
        }
        if ([IO.Path]::GetFileName($name) -match '^(settings\.json|monitor-preferences.*|session-selection.*|pet-position.*|context.*|auth\.json)$|\.(log|pdb)$') {
            throw "Unexpected private/runtime entry: $name"
        }
    }
} finally { $zip.Dispose() }
[IO.Compression.ZipFile]::ExtractToDirectory($Archive,$output)
$manifest=@(Get-Content -LiteralPath (Join-Path $output 'FILES-SHA256.json') -Raw | ConvertFrom-Json)
$covered=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($file in $manifest) {
    $path=[IO.Path]::GetFullPath((Join-Path $output $file.path))
    if (!$path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or !$covered.Add($file.path)) { throw 'Unsafe or duplicate manifest entry.' }
    if (!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -ne $file.bytes -or
        (Get-FileHash -LiteralPath $path).Hash -ne $file.sha256) { throw "File integrity mismatch: $($file.path)" }
}
foreach ($file in Get-ChildItem -LiteralPath $output -Recurse -File) {
    $relative=[IO.Path]::GetRelativePath($output,$file.FullName).Replace('\','/')
    if ($relative -ne 'FILES-SHA256.json' -and !$covered.Contains($relative)) { throw "Uncovered file: $relative" }
}
foreach ($required in @('codex_timezone.exe','codex_timezone_core.dll','flutter_windows.dll','Start-Monitor.cmd','Stop-Monitor.cmd','data/app.so')) {
    if (!$covered.Contains($required)) { throw "Missing runtime input: $required" }
}
$build=Get-Content -LiteralPath (Join-Path $output 'BUILD-INFO.json') -Raw | ConvertFrom-Json
if ($build.stage -ne $Stage) { throw 'Candidate stage mismatch.' }
if ($build.exeSha256 -ne (Get-FileHash (Join-Path $output 'codex_timezone.exe')).Hash -or
    $build.coreSha256 -ne (Get-FileHash (Join-Path $output 'codex_timezone_core.dll')).Hash) { throw 'Build identity mismatch.' }
Write-Output "PASS: ZIP checksum, safe paths and $($manifest.Count) file hashes"
Write-Output $output
