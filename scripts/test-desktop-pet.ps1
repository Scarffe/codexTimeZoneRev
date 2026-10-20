$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$executable = & (Join-Path $PSScriptRoot 'build-desktop-prototype.ps1') | Select-Object -Last 1
$evidence = Join-Path $root 'environment\stage-c-evidence'
New-Item -ItemType Directory -Force $evidence | Out-Null
$report = Join-Path $evidence "native-self-test-$([Guid]::NewGuid().ToString('N')).json"
$process = Start-Process -FilePath $executable -ArgumentList '--desktop-prototype','--prototype-self-test',"--prototype-report=$report" -WindowStyle Hidden -PassThru -Wait
if ($process.ExitCode -ne 0) { throw "Pet self-test failed: $($process.ExitCode)" }
$result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
if ($result.selfChecks -ne 21) { throw "Expected 21 checks, got $($result.selfChecks)" }
Write-Output "PASS: 21 native surface checks; $report"
