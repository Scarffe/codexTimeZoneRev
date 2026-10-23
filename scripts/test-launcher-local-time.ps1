param(
    [string]$OutputDirectory = 'environment/timezone-m3-validation-20261023-a/native-clock'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (![IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path $root $OutputDirectory
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$parentTzBefore = [Environment]::GetEnvironmentVariable('TZ', 'Process')
$systemZoneBefore = [TimeZoneInfo]::Local.ToSerializedString()

function RunConsole([string]$file, [string]$arguments, [AllowNull()]$tz, [bool]$setTz) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $file
    $start.Arguments = $arguments
    $start.WorkingDirectory = $output
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['TMP'] = $output
    $start.EnvironmentVariables['TEMP'] = $output
    if ($setTz) {
        $start.EnvironmentVariables.Remove('TZ')
        if ($null -ne $tz) { $start.EnvironmentVariables['TZ'] = $tz }
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (!$process.Start()) { throw "Could not start $file" }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(30000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "Owned console process exceeded 30 seconds: $file"
        }
        [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdout.GetAwaiter().GetResult()
            stderr = $stderr.GetAwaiter().GetResult()
        }
    } finally { $process.Dispose() }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (!(Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio locator not found.' }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or !$vs) { throw 'Visual Studio C++ build tools not found.' }
$vcvars = Join-Path $vs 'VC/Auxiliary/Build/vcvars64.bat'
$source = Join-Path $root 'flutter_app/windows/runner/tests/local_clock_environment_test.cpp'
$fixture = Join-Path $output 'local_clock_environment_test.exe'
$object = Join-Path $output 'local_clock_environment_test.obj'
# vcvars changes only this compiler child's environment.
$compileArguments = '/d /s /c ""{0}" >nul && cd /d "{4}" && set "TMP={4}" && set "TEMP={4}" && cl.exe /nologo /W4 /WX /std:c++17 /EHsc /MD /utf-8 /D_WIN32_WINNT=0x0A00 "{1}" /Fe:"{2}" /Fo:"{3}""' -f $vcvars, $source, $fixture, $object, $output
$build = RunConsole $env:ComSpec $compileArguments $null $false
$build.stdout + $build.stderr | Set-Content (Join-Path $output 'build.log') -Encoding utf8
if ($build.exitCode -ne 0) { throw "Native clock regression compilation failed; see $output/build.log" }

$runs = @()
foreach ($case in @(
    @{ name = 'unset'; value = $null },
    @{ name = 'America-Los_Angeles'; value = 'America/Los_Angeles' },
    @{ name = 'UTC'; value = 'UTC' },
    @{ name = 'PST8PDT'; value = 'PST8PDT' }
)) {
    $run = RunConsole $fixture '' $case.value $true
    $run.stdout | Set-Content (Join-Path $output ($case.name + '.json')) -Encoding utf8
    $run.stderr | Set-Content (Join-Path $output ($case.name + '.stderr.log')) -Encoding utf8
    $reading = $run.stdout | ConvertFrom-Json
    $runs += [pscustomobject]@{
        tz = $case.value
        exitCode = $run.exitCode
        reading = $reading
        stderr = $run.stderr
    }
}
[TimeZoneInfo]::ClearCachedData()
$parentTzAfter = [Environment]::GetEnvironmentVariable('TZ', 'Process')
$systemZoneAfter = [TimeZoneInfo]::Local.ToSerializedString()
$parentUnchanged = $parentTzBefore -ceq $parentTzAfter
$systemUnchanged = $systemZoneBefore -ceq $systemZoneAfter
$failed = @($runs | Where-Object { $_.exitCode -ne 0 -or !$_.reading.passed })
$passed = $failed.Count -eq 0 -and $parentUnchanged -and $systemUnchanged
[ordered]@{
    passed = $passed
    parentTzBefore = $parentTzBefore
    parentTzAfter = $parentTzAfter
    parentTzUnchanged = $parentUnchanged
    systemTimeZoneBefore = $systemZoneBefore
    systemTimeZoneAfter = $systemZoneAfter
    systemTimeZoneUnchanged = $systemUnchanged
    runs = $runs
} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $output 'acceptance.json') -Encoding utf8
if (!$passed) { throw "Native clock regression failed ($($failed.Count)/4 environments); see $output/acceptance.json" }
Write-Output 'PASS: 4 child environments x 2 UTC instants; CRT/Windows fields and offsets match; TZ removed; parent TZ and system timezone unchanged.'
Write-Output $output
