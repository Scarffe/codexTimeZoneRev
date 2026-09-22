param(
    [ValidateSet('doctor', 'test', 'build', 'run', 'preview')]
    [string]$Action = 'run',
    [string]$DevelopmentRoot = 'E:\development',
    [string]$FlutterSdk = ''
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (!$FlutterSdk) { $FlutterSdk = Join-Path $DevelopmentRoot 'flutter' }
$flutter = Join-Path $FlutterSdk 'bin\flutter.bat'
if (!(Test-Path -LiteralPath $flutter)) { throw "Flutter SDK not found: $flutter" }
if (!$env:PUB_CACHE) { $env:PUB_CACHE = Join-Path $DevelopmentRoot 'flutter-pub-cache' }
$env:PATH = "$(Join-Path $FlutterSdk 'bin');$(Join-Path $DevelopmentRoot 'Rust\cargo\bin');$env:PATH"
$env:CARGO_TARGET_DIR = Join-Path $projectRoot 'environment\flutter-cargo-target'
$cachedCargo = Join-Path $projectRoot 'environment\cargo'
if (Test-Path -LiteralPath $cachedCargo) { $env:CARGO_HOME = $cachedCargo }
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed ($LASTEXITCODE)." }
}
Push-Location (Join-Path $projectRoot 'flutter_app')
try {
    if ($Action -eq 'doctor') { Invoke-Checked $flutter @('doctor', '-v'); return }
    Invoke-Checked $flutter @('pub', 'get')
    if ($Action -eq 'test') {
        Invoke-Checked 'cargo' @('test', '--manifest-path', (Join-Path $projectRoot 'native\launcher_core\Cargo.toml'))
        Invoke-Checked $flutter @('analyze')
        Invoke-Checked $flutter @('test')
        return
    }
    if ($Action -eq 'preview') {
        Invoke-Checked $flutter @('run', '-d', 'windows', '--dart-define=UI_PREVIEW=true')
        return
    }
    Invoke-Checked 'cargo' @('build', '--release', '--manifest-path', (Join-Path $projectRoot 'native\launcher_core\Cargo.toml'))
    $env:CODEX_TZ_NATIVE_LIBRARY = Join-Path $env:CARGO_TARGET_DIR 'release\codex_timezone_core.dll'
    if ($Action -eq 'run') {
        Invoke-Checked $flutter @('run', '-d', 'windows')
    } else {
        Invoke-Checked $flutter @('build', 'windows', '--release')
        $output = Join-Path (Get-Location) 'build\windows\x64\runner\Release'
        Copy-Item -LiteralPath $env:CODEX_TZ_NATIVE_LIBRARY -Destination $output -Force
        $artifacts = Join-Path $projectRoot 'environment\artifacts'
        New-Item -ItemType Directory -Force -Path $artifacts | Out-Null
        # Package only application assets, never local settings or logs.
        $archivePath = Join-Path $artifacts 'CodexTimeZone-Flutter-windows-x64.zip'
        if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath }
        $archive = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            Get-ChildItem -LiteralPath $output -Recurse -File | ForEach-Object {
                $relative = [IO.Path]::GetRelativePath($output, $_.FullName).Replace('\', '/')
                if ($relative -match '^[^/]+\.(exe|dll)$' -or $relative -eq 'native_assets.json' -or
                    $relative -match '^data/(flutter_assets/|icudtl\.dat$|app\.so$)') {
                    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $relative) | Out-Null
                }
            }
        } finally { $archive.Dispose() }
        Write-Output "Release: $output"
        Write-Output "Portable ZIP: $artifacts\CodexTimeZone-Flutter-windows-x64.zip"
    }
} finally { Pop-Location }
