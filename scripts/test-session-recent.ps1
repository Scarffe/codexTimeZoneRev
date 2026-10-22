param([Parameter(Mandatory)][string]$RuntimeDirectory,[Parameter(Mandatory)][string]$NativeLibrary)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$source=(Resolve-Path -LiteralPath $RuntimeDirectory).Path
$library=(Resolve-Path -LiteralPath $NativeLibrary).Path
$directory=Join-Path $root ('environment/stage-i31-recent-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory|Out-Null
foreach($file in Get-ChildItem -LiteralPath $source -Recurse -File){
 $relative=[IO.Path]::GetRelativePath($source,$file.FullName).Replace('\','/')
 if($relative -match '^[^/]+\.(exe|dll)$' -or $relative -eq 'native_assets.json' -or $relative -match '^data/(flutter_assets/|icudtl\.dat$|app\.so$)'){
  $target=Join-Path $directory $relative;New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force|Out-Null;Copy-Item -LiteralPath $file.FullName -Destination $target
 }
}
Copy-Item -LiteralPath $library -Destination (Join-Path $directory 'codex_timezone_core.dll') -Force
@{version=1;enabled=$false;sessionAlerts=$true;mode=1;visible=$true;reducedMotion=$true}|ConvertTo-Json|Set-Content (Join-Path $directory 'monitor-preferences-v1.json') -Encoding utf8
$fixtureHome=Join-Path $directory 'fixture'
$sessionDir=Join-Path $fixtureHome 'sessions/2026/10/22'
New-Item -ItemType Directory -Path $sessionDir -Force|Out-Null
$session=Join-Path $sessionDir 'rollout-i-fixture.jsonl'
$offline=Join-Path $sessionDir 'rollout-i-fixture.offline'
$metadata=@{type='session_meta';payload=@{id='stage-i-fixture';source='vscode';cwd='isolated-fixture';timestamp='2026-10-22T00:00:00Z'}}|ConvertTo-Json -Compress
[IO.File]::WriteAllText($session,$metadata+"`n",[Text.UTF8Encoding]::new($false))
function Add-Event([string]$kind,[string]$id,[string]$path=$session){
 $value=@{type='event_msg';payload=@{type=$kind;turn_id=$id;started_at=1;completed_at=3;duration_ms=2000;time_to_first_token_ms=100}}|ConvertTo-Json -Compress
 [IO.File]::AppendAllText($path,$value+"`n",[Text.UTF8Encoding]::new($false))
}
Add-Event 'task_started' 'history';Add-Event 'task_complete' 'history'
$exe=Join-Path $directory 'codex_timezone.exe';$report=Join-Path $directory 'reminder-report.json'
$oldHome=$env:CODEX_HOME
$script:last=$null
function Wait-State([scriptblock]$condition){
 $deadline=(Get-Date).AddSeconds(30)
 do{
  Start-Sleep -Milliseconds 250
  try{$script:last=Get-Content -LiteralPath $report -Raw|ConvertFrom-Json}catch{$script:last=$null}
  if($script:last -and (& $condition $script:last)){return}
 }while((Get-Date)-lt $deadline)
 throw 'Expected session state was not observed; see reminder-report.json'
}
function Stop-Owned{
 $owned=@(Get-Process codex_timezone -ErrorAction SilentlyContinue|Where-Object Path -eq $exe)
 if($owned.Count){
  Start-Process -FilePath $exe -ArgumentList '--desktop-monitor','--isolated-instance','--monitor-exit' -WindowStyle Hidden -Wait
  foreach($p in $owned){if(!$p.WaitForExit(15000)){throw 'Owned test instance did not exit normally'}}
 }
}
$script:launches=0
function Start-Owned([int]$status=2){
 $script:expectedStatus=$status
 if(Test-Path -LiteralPath $report){Remove-Item -LiteralPath $report}
 $launchArgs=@('--desktop-monitor','--isolated-instance',"--monitor-report=$report")
 if($script:launches -eq 0){$launchArgs+=('--observe-session='+$session)}
 $script:launches++
 Start-Process -FilePath $exe -ArgumentList $launchArgs -WindowStyle Hidden|Out-Null
 Wait-State {param($v) $v.tray -and $v.paused -and $v.sessionStatus -eq $script:expectedStatus}
}
try{
 $env:CODEX_HOME=$fixtureHome
 Start-Owned
 if($script:last.sessionAlertsShown -ne 0){throw 'Historical completion alerted'}
 Copy-Item $report (Join-Path $directory 'history-silent.json')
 Add-Event 'task_started' 'live';Wait-State {param($v) $v.sessionStatus -eq 1}
 Add-Event 'task_complete' 'live';Wait-State {param($v) $v.sessionAlertsShown -eq 1 -and $v.sessionBubble -and $v.sessionFocusChecks -eq 1}
 if(!$script:last.sessionAlertKeptFocus -or $script:last.bubbleForeground -or $script:last.sessionFocusChecks -ne 1){throw 'Session bubble changed focus'}
 Copy-Item $report (Join-Path $directory 'first-alert-focus.json')
 Add-Event 'task_complete' 'live';Start-Sleep -Seconds 5
 Wait-State {param($v) $v.sessionStatus -eq 2}
 if($script:last.sessionAlertsShown -ne 1){throw 'Duplicate completion alerted'}
 Add-Event 'task_started' 'cancel';Wait-State {param($v) $v.sessionStatus -eq 1}
 Add-Event 'turn_aborted' 'cancel';Wait-State {param($v) $v.sessionStatus -eq 3 -and !$v.sessionBubble}
 if($script:last.sessionAlertsShown -ne 1){throw 'Cancellation impersonated completion'}
 Copy-Item $report (Join-Path $directory 'cancel-silent.json')
 Rename-Item -LiteralPath $session -NewName 'rollout-i-fixture.offline'
 Wait-State {param($v) $v.sessionStatus -eq 4 -and !$v.sessionBubble}
 if($script:last.sessionAlertsShown -ne 1){throw 'Read failure impersonated completion'}
 Copy-Item $report (Join-Path $directory 'read-failure-unknown.json')
 Add-Event 'task_started' 'during-error' $offline;Add-Event 'task_complete' 'during-error' $offline
 Rename-Item -LiteralPath $offline -NewName 'rollout-i-fixture.jsonl'
 Wait-State {param($v) $v.sessionStatus -eq 2};Start-Sleep -Seconds 3
 Wait-State {param($v) $v.sessionStatus -eq 2}
 if($script:last.sessionAlertsShown -ne 1){throw 'Read recovery replayed an ending'}
 [IO.File]::WriteAllText($session,$metadata+"`n",[Text.UTF8Encoding]::new($false))
 Add-Event 'task_started' 'rewrite';Add-Event 'task_complete' 'rewrite'
 Wait-State {param($v) $v.sessionStatus -eq 2};Start-Sleep -Seconds 3
 Wait-State {param($v) $v.sessionStatus -eq 2}
 if($script:last.sessionAlertsShown -ne 1){throw 'Log reset replayed an ending'}
 Add-Event 'task_started' 'fresh';Wait-State {param($v) $v.sessionStatus -eq 1}
 Add-Event 'task_complete' 'fresh';Wait-State {param($v) $v.sessionAlertsShown -eq 2 -and $v.sessionBubble -and $v.sessionFocusChecks -eq 2}
 if(!$script:last.sessionAlertKeptFocus -or $script:last.bubbleForeground -or $script:last.attempts -ne 0){throw 'Focus or read-only quota constraint failed'}
 Copy-Item $report (Join-Path $directory 'second-alert-focus.json')
 Stop-Owned;Start-Owned
 if($script:last.sessionAlertsShown -ne 0){throw 'Restart replayed history'}
 $saved=Get-Content (Join-Path $directory 'session-selection-v1.json') -Raw|ConvertFrom-Json
 if(!$saved.path -or $saved.id -ne 'stage-i-fixture'){throw 'Selection identity was not saved'}
 Copy-Item $report (Join-Path $directory 'restored-history-silent.json')
 Stop-Owned
 Rename-Item -LiteralPath $session -NewName 'rollout-i-fixture.offline'
 Start-Owned 4
 if($script:last.sessionAlertsShown -ne 0){throw 'Missing restored file alerted'}
 Copy-Item $report (Join-Path $directory 'missing-restored-unknown.json')
 Stop-Owned
 Rename-Item -LiteralPath $offline -NewName 'rollout-i-fixture.jsonl'
 Start-Owned
 if($script:last.sessionAlertsShown -ne 0){throw 'Returned file replayed history'}
 @{passed=$true;historySilent=$true;duplicateSilent=$true;cancelSilent=$true;readFailureUnknown=$true;recoverySilent=$true;resetSilent=$true;restartSilent=$true;selectionRestored=$true;missingRestoredUnknown=$true;sessionFocusChecks=2;source='isolated synthetic session; no current Codex session edited'}|ConvertTo-Json|Set-Content (Join-Path $directory 'ACCEPTANCE.json')
 Write-Output 'PASS: historical/duplicate/cancel/error/recovery/reset/restart suppression, live reminders, focus and zero quota queries'
}finally{
 if(Test-Path -LiteralPath $offline){Rename-Item -LiteralPath $offline -NewName 'rollout-i-fixture.jsonl'}
 Stop-Owned
 $env:CODEX_HOME=$oldHome
 if(@(Get-Process codex_timezone -ErrorAction SilentlyContinue|Where-Object Path -eq $exe).Count){throw 'Owned instance remains'}
}
Write-Output $directory
