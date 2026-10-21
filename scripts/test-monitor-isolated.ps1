param([Parameter(Mandatory)][string]$Archive)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$audit=& (Join-Path $PSScriptRoot 'test-stage-d-package.ps1') -Stage G -Archive $Archive
$directory=$audit|Select-Object -Last 1
$exe=Join-Path $directory 'codex_timezone.exe'
$report=Join-Path $directory 'isolated-smoke.json'
$initial=$null;$ownedId=0;$ownedStarted=$null;$state=$null
try {
 $initial=Start-Process $exe -ArgumentList @('--desktop-monitor','--isolated-instance',"--monitor-report=$report") -WindowStyle Hidden -PassThru
 $deadline=(Get-Date).AddSeconds(25)
 do {Start-Sleep -Milliseconds 200;if(Test-Path $report){try{$state=Get-Content $report -Raw|ConvertFrom-Json}catch{$state=$null}}} while((!$state -or !$state.tray) -and (Get-Date)-lt $deadline)
 if(!$state -or !$state.tray){throw 'Isolated monitor did not initialize'}
 $ownedId=[int]$state.pid;$process=Get-Process -Id $ownedId
 if($process.Path -ne $exe){throw 'Unexpected isolated executable path'}
 $ownedStarted=$process.StartTime
 $again=Start-Process $exe -ArgumentList @('--desktop-monitor','--isolated-instance') -WindowStyle Hidden -PassThru
 if(!$again.WaitForExit(20000) -or $again.ExitCode -ne 0){throw 'Repeated isolated launch did not exit successfully'}
 $deadline=(Get-Date).AddSeconds(20)
 do {Start-Sleep -Milliseconds 250;$state=Get-Content $report -Raw|ConvertFrom-Json} while(!$state.mainVisible -and (Get-Date)-lt $deadline)
 if(!$state.mainVisible){throw 'Repeated launch did not restore main window'}
 $same=@(Get-Process -Name codex_timezone -ErrorAction SilentlyContinue|Where-Object Path -eq $exe)
 if($same.Count -ne 1){throw 'Duplicate isolated monitor survived'}
} finally {
 # Only our new, explicit isolated directory is ever sent an exit request.
 Start-Process $exe -ArgumentList @('--desktop-monitor','--isolated-instance','--monitor-exit') -WindowStyle Hidden -Wait
 if($ownedId) {
  $remaining=Get-Process -Id $ownedId -ErrorAction SilentlyContinue
  if($remaining -and $remaining.Path -eq $exe -and $remaining.StartTime -eq $ownedStarted) {
   if(!$remaining.WaitForExit(45000)){ $remaining.Kill();$remaining.WaitForExit();throw 'Isolated monitor needed forced cleanup; smoke failed' }
  }
 }
 if($initial -and !$initial.HasExited -and !$initial.WaitForExit(5000)){throw 'Bootstrap process remained alive'}
}
@{passed=$true;mainRestored=$state.mainVisible;repeatedLaunchKeptOneProcess=$true;ownedProcessExited=$true;directory=$directory} | ConvertTo-Json | Set-Content (Join-Path $directory 'acceptance.json') -Encoding utf8
Write-Output 'PASS: isolated monitor restore and automatic cleanup'
Write-Output $directory

