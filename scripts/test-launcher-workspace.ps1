param(
 [string]$RuntimeDirectory='',
 [string]$NativeLibrary='',
 [string]$Archive=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$directory=Join-Path $root ('environment/stage-w-workspace-'+[guid]::NewGuid().ToString('N'))
$prefix=[IO.Path]::GetFullPath($directory)+[IO.Path]::DirectorySeparatorChar
$checks=[Collections.Generic.List[string]]::new()
$script:last=$null
$script:failure=$null
$oldHome=$env:CODEX_HOME
function Assert-That([bool]$condition,[string]$message) {
 if(!$condition){throw $message};$checks.Add($message)
}
function Save-Evidence([string]$name) {
 Copy-Item -LiteralPath $report -Destination (Join-Path $directory "$name.json")
}
function Wait-State([scriptblock]$condition,[string]$description) {
 $deadline=(Get-Date).AddSeconds(35)
 do {
  Start-Sleep -Milliseconds 250
  try{$script:last=Get-Content -LiteralPath $report -Raw|ConvertFrom-Json}catch{$script:last=$null}
  if($script:last -and (& $condition $script:last)){return}
 }while((Get-Date)-lt $deadline)
 throw "Timed out: $description; see $report"
}
function Owned-Processes {
 @(Get-Process codex_timezone -ErrorAction SilentlyContinue|Where-Object Path -eq $exe)
}
function Invoke-Control([string]$action) {
 $p=Start-Process -FilePath $exe -ArgumentList '--isolated-instance',"--workspace-test-action=$action" -WindowStyle Hidden -PassThru
 if(!$p.WaitForExit(15000) -or $p.ExitCode -ne 0){throw "Control failed: $action"}
}
function Stop-Owned {
 $owned=@(Owned-Processes)
 if($owned.Count){
  $command=Start-Process -FilePath $exe -ArgumentList '--isolated-instance','--monitor-exit' -WindowStyle Hidden -PassThru
  if(!$command.WaitForExit(15000) -or $command.ExitCode -ne 0){throw 'Explicit same-directory exit command failed'}
  foreach($p in $owned){if(!$p.WaitForExit(30000)){throw 'Owned test instance did not exit normally; no forced cleanup performed'}}
 }
 if(@(Owned-Processes).Count){throw 'Exact-path test process remains'}
}
function Start-Owned([bool]$background=$false) {
 if(Test-Path -LiteralPath $report){Remove-Item -LiteralPath $report}
 $arguments=@('--isolated-instance','--monitor-test-controls',"--monitor-report=$report")
 if($background){$arguments+='--desktop-monitor'}
 # Normal startup is intentionally visible; background helpers alone are hidden.
 if($background){Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden|Out-Null}
 else {Start-Process -FilePath $exe -ArgumentList $arguments|Out-Null}
 Wait-State {param($v) $v.tray -and $v.bridgeReady} 'permanent channel and tray ready'
 Assert-That (@(Owned-Processes).Count -eq 1) 'One exact-path owner initialized'
 Assert-That ($script:last.petPaused -and !$script:last.visible) 'Production pet remains paused'
}
function Assert-Preserved {
 $hashResults=@(foreach($baselineName in @('installed','packages')) {
  foreach($entry in @(Get-Content -LiteralPath (Join-Path $root "environment/workspace-before-$baselineName.json") -Raw|ConvertFrom-Json)) {
   $present=Test-Path -LiteralPath $entry.Path -PathType Leaf
   $hash=if($present){(Get-FileHash -LiteralPath $entry.Path).Hash}else{''}
   [ordered]@{path=$entry.Path;unchanged=($hash -eq $entry.Hash);expected=$entry.Hash;actual=$hash}
  }
 })
 $processResults=@(foreach($entry in @(Get-Content -LiteralPath (Join-Path $root 'environment/workspace-before-processes.json') -Raw|ConvertFrom-Json)) {
  $p=Get-Process -Id $entry.Id -ErrorAction SilentlyContinue
  [ordered]@{id=$entry.Id;path=$entry.Path;started=$entry.started;preserved=($null -ne $p -and $p.Path -eq $entry.Path -and $p.StartTime.ToUniversalTime().Ticks -eq ([DateTimeOffset]$entry.started).UtcTicks)}
 })
 @{hashes=$hashResults;processes=$processResults;ownedProcessesRemaining=@(Owned-Processes).Count}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $directory 'preservation.json') -Encoding utf8
 Assert-That (@($hashResults|Where-Object {!$_.unchanged}).Count -eq 0) 'Original installed binaries and packages retain their hashes'
 Assert-That (@($processResults|Where-Object {!$_.preserved}).Count -eq 0) 'All baseline Codex process identities remain present'
}
foreach($baselineName in @('processes','packages','installed')) {
 $path=Join-Path $root "environment/workspace-before-$baselineName.json"
 if(!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -lt 3 -or @(Get-Content -LiteralPath $path -Raw|ConvertFrom-Json).Count -eq 0){throw "Nonempty original baseline required: $path"}
}
if($Archive) {
 $Archive=(Resolve-Path -LiteralPath $Archive).Path
 $checksum=(Get-Content -LiteralPath "$Archive.sha256" -Raw).Trim() -split '\s+',2
 Assert-That ($checksum.Count -eq 2 -and $checksum[1] -eq [IO.Path]::GetFileName($Archive) -and (Get-FileHash -LiteralPath $Archive).Hash -eq $checksum[0]) 'Archive checksum matches'
 $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
 try {
  $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($entry in $zip.Entries) {
   $name=$entry.FullName.Replace('\','/')
   $target=[IO.Path]::GetFullPath((Join-Path $directory $name))
   if([IO.Path]::IsPathRooted($name) -or $name.Split('/') -contains '..' -or !$target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or !$names.Add($name)){throw "Unsafe ZIP entry: $name"}
   if([IO.Path]::GetFileName($name) -match '^(settings\.json|monitor-preferences.*|session-selection.*|pet-position.*|context.*|auth\.json)$|\.(log|pdb)$'){throw "Private/runtime archive entry: $name"}
  }
 }finally{$zip.Dispose()}
 [IO.Compression.ZipFile]::ExtractToDirectory($Archive,$directory)
 $covered=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($item in @(Get-Content -LiteralPath (Join-Path $directory 'FILES-SHA256.json') -Raw|ConvertFrom-Json)) {
  $target=[IO.Path]::GetFullPath((Join-Path $directory $item.path))
  if(!$target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or !$covered.Add($item.path)){throw 'Unsafe manifest entry'}
  Assert-That ((Test-Path -LiteralPath $target -PathType Leaf) -and (Get-Item -LiteralPath $target).Length -eq $item.bytes -and (Get-FileHash -LiteralPath $target).Hash -eq $item.sha256) "Manifest integrity: $($item.path)"
 }
 foreach($file in Get-ChildItem -LiteralPath $directory -Recurse -File) {
  $relative=[IO.Path]::GetRelativePath($directory,$file.FullName).Replace('\','/')
  if($relative -ne 'FILES-SHA256.json' -and !$covered.Contains($relative)){throw "Uncovered archive file: $relative"}
 }
 $build=Get-Content -LiteralPath (Join-Path $directory 'BUILD-INFO.json') -Raw|ConvertFrom-Json
 Assert-That ($build.stage -eq 'W') 'Archive declares Stage W'
 foreach($required in @('codex_timezone.exe','codex_timezone_core.dll','flutter_windows.dll','data/app.so','Start-Trial.cmd','Stop-Trial.cmd','Start-Monitor.cmd','Stop-Monitor.cmd')) {
  Assert-That ($covered.Contains($required)) "Required candidate input: $required"
 }
 Assert-That ($build.exeSha256 -eq (Get-FileHash -LiteralPath (Join-Path $directory 'codex_timezone.exe')).Hash -and $build.coreSha256 -eq (Get-FileHash -LiteralPath (Join-Path $directory 'codex_timezone_core.dll')).Hash) 'Build identity matches runtime hashes'
 Assert-That ((Get-Content -LiteralPath (Join-Path $directory 'Start-Trial.cmd') -Raw) -match '--isolated-instance' -and (Get-Content -LiteralPath (Join-Path $directory 'Start-Trial.cmd') -Raw) -notmatch '--desktop-monitor') 'Trial launcher starts the visible isolated workspace'
 Assert-That ((Get-Content -LiteralPath (Join-Path $directory 'Stop-Trial.cmd') -Raw) -match '--isolated-instance --monitor-exit') 'Trial stop explicitly exits its isolated instance'
 foreach($entry in @('Start-Monitor.cmd','Stop-Monitor.cmd')) {
  Assert-That ((Get-Content -LiteralPath (Join-Path $directory $entry) -Raw) -match '--desktop-monitor --isolated-instance') "Background entry is isolated: $entry"
 }
} else {
 if(!$RuntimeDirectory -or !$NativeLibrary){throw 'Supply Archive or both RuntimeDirectory and NativeLibrary'}
 $source=(Resolve-Path -LiteralPath $RuntimeDirectory).Path
 New-Item -ItemType Directory -Path $directory|Out-Null
 foreach($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
  $relative=[IO.Path]::GetRelativePath($source,$file.FullName).Replace('\','/')
  if($relative -eq 'codex_timezone.exe' -or $relative -match '^[^/]+\.dll$' -or $relative -eq 'native_assets.json' -or $relative -match '^data/(flutter_assets/|icudtl\.dat$|app\.so$)') {
   $target=Join-Path $directory $relative
   New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force|Out-Null
   Copy-Item -LiteralPath $file.FullName -Destination $target
  }
 }
 Copy-Item -LiteralPath (Resolve-Path -LiteralPath $NativeLibrary).Path -Destination (Join-Path $directory 'codex_timezone_core.dll') -Force
}
$exe=Join-Path $directory 'codex_timezone.exe'
$report=Join-Path $directory 'workspace-report.json'
$fixtureHome=Join-Path $directory 'fixture-home'
$sessionDir=Join-Path $fixtureHome 'sessions/2026/10/22'
New-Item -ItemType Directory -Path $sessionDir -Force|Out-Null
$session=Join-Path $sessionDir 'rollout-w-fixture.jsonl'
$offline="$session.offline"
$preferences=Join-Path $directory 'monitor-preferences-v1.json'
$selection=Join-Path $directory 'session-selection-v1.json'
function Add-Event([string]$kind,[string]$id,[string]$path=$session) {
 $event=@{type='event_msg';payload=@{type=$kind;turn_id=$id;started_at=1;completed_at=3;duration_ms=2000;time_to_first_token_ms=100}}|ConvertTo-Json -Compress
 [IO.File]::AppendAllText($path,$event+"`n",[Text.UTF8Encoding]::new($false))
}
try {
 $env:CODEX_HOME=$fixtureHome
 Start-Owned
 Wait-State {param($v) $v.mainVisible -and $v.workspace -eq 'launcher' -and !$v.keepAlive -and $v.attempts -eq 0} 'fresh normal visible launcher without quota calls'
 Save-Evidence 'fresh-visible'
 Invoke-Control 'close'
 $deadline=(Get-Date).AddSeconds(20)
 while(@(Owned-Processes).Count -and (Get-Date)-lt $deadline){Start-Sleep -Milliseconds 250}
 Assert-That (@(Owned-Processes).Count -eq 0) 'Idle ordinary close exits normally'
 Start-Owned $true
 Wait-State {param($v) !$v.mainVisible -and $v.backgroundStart -and $v.attempts -eq 0} 'background startup hidden'
 Save-Evidence 'background-hidden'
 $ownerId=$script:last.pid
 $again=Start-Process -FilePath $exe -ArgumentList '--isolated-instance' -PassThru
 Assert-That ($again.WaitForExit(15000) -and $again.ExitCode -eq 0) 'Normal cross-launch forwards to existing owner'
 Wait-State {param($v) $v.mainVisible -and $v.pid -eq $ownerId} 'normal cross-launch restores original background owner'
 Assert-That (@(Owned-Processes).Count -eq 1) 'Normal/background cross-launch keeps one process'
 Invoke-Control 'close';Wait-State {param($v) !$v.mainVisible} 'background-start close hides'
 Invoke-Control 'restore';Wait-State {param($v) $v.mainVisible -and $v.pid -eq $ownerId} 'restore opens same main'
 Save-Evidence 'background-restored'
 Stop-Owned
 $metadata=@{type='session_meta';payload=@{id='stage-w-fixture';source='vscode';cwd='isolated-fixture';timestamp='2026-10-22T00:00:00Z'}}|ConvertTo-Json -Compress
 [IO.File]::WriteAllText($session,$metadata+"`n",[Text.UTF8Encoding]::new($false))
 Add-Event 'task_started' 'history';Add-Event 'task_complete' 'history'
 @{version=1;enabled=$false;sessionAlerts=$true;visible=$true;mode=1}|ConvertTo-Json|Set-Content -LiteralPath $preferences -Encoding utf8
 @{version=1;path=$session;id='stage-w-fixture'}|ConvertTo-Json|Set-Content -LiteralPath $selection -Encoding utf8
 Start-Owned
 Wait-State {param($v) $v.mainVisible -and $v.keepAlive -and $v.paused -and $v.sessionStatus -eq 2} 'session-only selection restored without quota monitoring'
 Assert-That ($script:last.notificationAttempts -eq 0 -and $script:last.attempts -eq 0) 'Historical completion remains silent with zero quota calls'
 Save-Evidence 'session-restored-silent'
 $ownerId=$script:last.pid
 $again=Start-Process -FilePath $exe -ArgumentList '--isolated-instance','--desktop-monitor' -WindowStyle Hidden -PassThru
 Assert-That ($again.WaitForExit(15000) -and $again.ExitCode -eq 0) 'Background cross-launch forwards to normal owner'
 Wait-State {param($v) $v.pid -eq $ownerId} 'normal owner survives cross-launch'
 Assert-That (@(Owned-Processes).Count -eq 1) 'Background/normal cross-launch keeps one process'
 Invoke-Control 'legacy-show';Invoke-Control 'resume'
 Wait-State {param($v) $v.petPaused -and !$v.visible -and $v.testActionInjections -ge 2} 'legacy and resume cannot resurrect pet'
 Invoke-Control 'close';Wait-State {param($v) !$v.mainVisible -and $v.keepAlive} 'session-only close hides'
 $noticeBase=$script:last.notificationAttempts
 Add-Event 'task_started' 'live';Wait-State {param($v) $v.sessionStatus -eq 1} 'hidden session collector observes start'
 Add-Event 'task_complete' 'live'
 Wait-State {param($v) $v.sessionStatus -eq 2 -and $v.notificationKind -eq 'session' -and $v.notificationAttempts -eq ($noticeBase+1)} 'live hidden completion publishes independent notice'
 Assert-That ($script:last.notificationKeptFocus -and !$script:last.mainVisible -and !$script:last.visible) 'Notification publication preserves focus and hidden surfaces'
 Save-Evidence 'live-session-notice'
 $count=$script:last.notificationAttempts
 Add-Event 'task_complete' 'live';Start-Sleep -Seconds 4
 Wait-State {param($v) $v.sessionStatus -eq 2} 'duplicate terminal consumed'
 Assert-That ($script:last.notificationAttempts -eq $count) 'Duplicate completion does not republish'
 Invoke-Control 'click'
 Wait-State {param($v) $v.mainVisible -and $v.workspace -eq 'monitor' -and $v.notificationClickRoute -eq 'sessionDetails'} 'injected session notification callback opens monitor page'
 Assert-That ($script:last.notificationClickInjections -eq 1) 'Session callback is explicitly recorded as an injection'
 Save-Evidence 'session-click-injected'
 Invoke-Control 'quota'
 Wait-State {param($v) $v.notificationKind -eq 'quota' -and $v.notificationAttempts -eq ($count+1)} 'injected quota notice published'
 Invoke-Control 'click'
 Wait-State {param($v) $v.mainVisible -and $v.workspace -eq 'monitor' -and $v.notificationClickRoute -eq 'monitorDetails'} 'injected quota callback opens monitor page'
 Assert-That ($script:last.notificationClickInjections -eq 2 -and $script:last.notificationKeptFocus) 'Quota callback injection and publication focus are recorded'
 Save-Evidence 'quota-click-injected'
 $count=$script:last.notificationAttempts
 Rename-Item -LiteralPath $session -NewName ([IO.Path]::GetFileName($offline))
 Wait-State {param($v) $v.sessionStatus -eq 4} 'missing selected fixture becomes unknown'
 Save-Evidence 'session-missing-unknown'
 Add-Event 'task_started' 'while-missing' $offline;Add-Event 'task_complete' 'while-missing' $offline
 Rename-Item -LiteralPath $offline -NewName ([IO.Path]::GetFileName($session))
 Wait-State {param($v) $v.sessionStatus -eq 2} 'fixture restores'
 Start-Sleep -Seconds 3;Wait-State {param($v) $v.sessionStatus -eq 2} 'restored history observed'
 Assert-That ($script:last.notificationAttempts -eq $count) 'Recovery does not replay completion history'
 Save-Evidence 'recovery-silent'
 Stop-Owned;Start-Owned
 Wait-State {param($v) $v.keepAlive -and $v.sessionStatus -eq 2 -and $v.workspace -eq 'launcher'} 'restart restores selected collector on launcher'
 Assert-That ($script:last.notificationAttempts -eq 0 -and $script:last.attempts -eq 0) 'Restart history stays silent and quota remains disabled'
 Save-Evidence 'restart-silent'
}catch{$script:failure=$_.ToString();throw}
finally {
 try{Stop-Owned}catch {
  $cleanupFailure='Cleanup failed: '+$_.ToString()
  $script:failure=if($script:failure){$script:failure+"; "+$cleanupFailure}else{$cleanupFailure}
  Write-Warning $cleanupFailure
 }finally {
  $env:CODEX_HOME=$oldHome
  if(Test-Path -LiteralPath $offline){Rename-Item -LiteralPath $offline -NewName ([IO.Path]::GetFileName($session))}
  try{Assert-Preserved}catch{if(!$script:failure){$script:failure=$_.ToString()};Write-Warning $_}
  @{passed=(!$script:failure);failure=$script:failure;checks=$checks.ToArray();directory=$directory;source='isolated synthetic session and explicitly injected native controls';physicalNotificationDisplay='NOT_RUN';physicalNotificationClick='NOT_RUN';physicalUiNavigation='NOT_RUN';forcedCleanup=$false;remainingOwnedProcesses=@(Owned-Processes).Count}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $directory 'ACCEPTANCE.json') -Encoding utf8
 }
}
if($script:failure){throw $script:failure}
Write-Output "PASS: $($checks.Count) assertions; exact-path normal cleanup; shell acceptance only, no physical notification claim"
Write-Output $directory
