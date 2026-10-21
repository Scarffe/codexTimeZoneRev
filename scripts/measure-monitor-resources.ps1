param(
  [Parameter(Mandatory)][int]$ProcessId,
  [Parameter(Mandatory)][string]$Report,
  [Parameter(Mandatory)][string]$Output,
  [ValidateRange(60,3600)][int]$DurationSeconds=720,
  [ValidateRange(1,30)][int]$PeriodSeconds=5
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$outputPath=[IO.Path]::GetFullPath((Join-Path $root $Output))
$allowed=[IO.Path]::GetFullPath((Join-Path $root 'environment'))+[IO.Path]::DirectorySeparatorChar
if(!$outputPath.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Write sampling results only under environment.' }
if(Test-Path -LiteralPath $outputPath) { throw 'Do not overwrite prior resource evidence.' }
$reportPath=(Resolve-Path -LiteralPath $Report).Path
$targetProcess=Get-Process -Id $ProcessId
$started=$targetProcess.StartTime.ToUniversalTime()
$watch=[Diagnostics.Stopwatch]::StartNew()
$previousCpu=$targetProcess.TotalProcessorTime.TotalMilliseconds
$previousSeconds=0.0
$logical=[Environment]::ProcessorCount
while($watch.Elapsed.TotalSeconds -le $DurationSeconds) {
  $targetProcess=Get-Process -Id $ProcessId -ErrorAction Stop
  if($targetProcess.StartTime.ToUniversalTime() -ne $started) { throw 'PID was reused.' }
  $seconds=$watch.Elapsed.TotalSeconds
  $cpu=$targetProcess.TotalProcessorTime.TotalMilliseconds
  $oneCore=if($seconds-$previousSeconds -gt 0.1) { ($cpu-$previousCpu)/1000/($seconds-$previousSeconds)*100 } else { 0 }
  $snapshot=Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
  [pscustomobject][ordered]@{
    utc=[DateTime]::UtcNow.ToString('o');elapsedSeconds=[math]::Round($seconds,2);
    pid=$ProcessId;cpuOneCorePercent=[math]::Round($oneCore,3);
    cpuMachinePercent=[math]::Round($oneCore/$logical,3);logicalProcessors=$logical;
    privateMiB=[math]::Round($targetProcess.PrivateMemorySize64/1MB,3);
    workingMiB=[math]::Round($targetProcess.WorkingSet64/1MB,3);
    processHandles=$targetProcess.HandleCount;threads=$targetProcess.Threads.Count;
    gdiObjects=$snapshot.gdiObjects;userObjects=$snapshot.userObjects;
    mode=$snapshot.mode;state=$snapshot.animationState;frame=$snapshot.animationFrame;
    frames=$snapshot.animationFrames;renders=$snapshot.renders;timer=$snapshot.animationTimer;
    reduced=$snapshot.reducedMotion;visible=$snapshot.visible;suspended=$snapshot.animationSuspended;
    test=$snapshot.animationTest;soakStep=$snapshot.soakStep;drawFailures=$snapshot.drawFailures;
    attempts=$snapshot.attempts;revision=$snapshot.revision;failures=$snapshot.failures;
    mainVisible=$snapshot.mainVisible;petForeground=$snapshot.petForeground
  } | Export-Csv -LiteralPath $outputPath -Append -NoTypeInformation -Encoding utf8
  $previousCpu=$cpu; $previousSeconds=$seconds
  Start-Sleep -Seconds $PeriodSeconds
}
Write-Output "PASS: resource sampling complete: $outputPath"
