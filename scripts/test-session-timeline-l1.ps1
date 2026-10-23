param(
 [string]$RuntimeDirectory='', [string]$NativeLibrary='', [string]$Archive='',
 [switch]$FfiOnly, [switch]$FfiChild, [string]$ReceiptPath='', [switch]$InjectChildStall,
 [string]$VerifiedFfiReceipt=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$fresh=Join-Path $root 'environment/stage-l1-core/codex_timezone_core.dll'
if(!$NativeLibrary){$NativeLibrary=$fresh}
$NativeLibrary=(Resolve-Path -LiteralPath $NativeLibrary).Path
if($NativeLibrary -ne (Resolve-Path -LiteralPath $fresh).Path){throw 'L1 requires the exact newly staged L1 core'}
$checks=[Collections.Generic.List[string]]::new()
function Assert-That([bool]$condition,[string]$description){if(!$condition){throw $description};$checks.Add($description)}
function Write-Json($value,[string]$path){$value|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $path -Encoding utf8}
function Read-Json([string]$path){Get-Content -LiteralPath $path -Raw|ConvertFrom-Json}
function Write-Fixture([string]$fixtureHome,[string]$name,[int]$count=4,[switch]$Partial,[switch]$InvalidRows){
 $sessions=Join-Path $fixtureHome 'sessions/2026/10/23'
 New-Item -ItemType Directory -Path $sessions -Force|Out-Null
 $path=Join-Path $sessions "rollout-$name.jsonl"
 $lines=[Collections.Generic.List[string]]::new()
 function Record($value){$lines.Add(($value|ConvertTo-Json -Depth 12 -Compress))}
 Record @{type='session_meta';payload=@{id='session';source='vscode';cwd='synthetic-l1';timestamp='2026-10-23T00:00:00Z'}}
 Record @{type='turn_context';payload=@{turn_id='turn';model='model';effort='high';service_tier='standard'}}
 Record @{type='event_msg';payload=@{type='task_started';turn_id='turn'}}
 $usage=@{input_tokens=100;output_tokens=20;reasoning_output_tokens=5}
 Record @{type='token_usage_record';timestamp='1970-01-01T00:00:02.000Z';payload=@{turn_id='turn';thread_id='session';response_id='response';model='model';usage=$usage;turn_token_usage=$usage;thread_token_usage=$usage}}
 $kinds=@('AgentMessage','Reasoning','CommandExecution','FutureSyntheticItem')
 for($i=0;$i -lt $count;$i++){
  $start=1000+$i*5;$end=$start+100
  $payload=@{type='item_completed';turn_id='turn';started_at_ms=$start;completed_at_ms=$end;item=@{id=('PRIVATE_ITEM_'+$i);type=$kinds[$i%4];content='PRIVATE_ANSWER';command='PRIVATE_COMMAND';arguments='PRIVATE_ARGS';prompt='PRIVATE_PROMPT'}}
  if($InvalidRows){
   switch($i){0{$payload.completed_at_ms=$start};1{$payload.completed_at_ms=$start-1};2{$payload.Remove('started_at_ms')};3{$payload.started_at_ms=4000;$payload.completed_at_ms=4100}}
  }
  Record @{type='event_msg';payload=$payload}
 }
 Record @{type='event_msg';payload=@{type='task_complete';turn_id='turn';started_at=1;completed_at=3;duration_ms=2000;time_to_first_token_ms=100}}
 if($Partial){$lines.Add('{synthetic malformed history}')}
 [IO.File]::WriteAllLines($path,$lines,[Text.UTF8Encoding]::new($false))
 (Get-Item -LiteralPath $path).IsReadOnly=$true
 return $path
}
if($FfiChild){
 if(!$ReceiptPath -or (Test-Path -LiteralPath $ReceiptPath)){throw 'New child receipt required'}
 $fixtureHome=Join-Path (Split-Path -Parent $ReceiptPath) 'ffi-home'
 $env:CODEX_HOME=$fixtureHome
 # No credential discovery or live network request is used by this smoke.
 $env:HTTP_PROXY='http://192.0.2.1:9';$env:HTTPS_PROXY=$env:HTTP_PROXY;$env:ALL_PROXY=$env:HTTP_PROXY
 $complete=Write-Fixture $fixtureHome 'complete'
 $limited=Write-Fixture $fixtureHome 'limited' 205
 $partial=Write-Fixture $fixtureHome 'partial' 4 -Partial
 $invalid=Write-Fixture $fixtureHome 'invalid' 4 -InvalidRows
 $fixtureBefore=@(Get-ChildItem -LiteralPath $fixtureHome -Recurse -File|ForEach-Object {@{path=$_.FullName;hash=(Get-FileHash -LiteralPath $_.FullName).Hash}})
 Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public sealed class L1Ffi : IDisposable {
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate uint Abi();
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr Call(IntPtr request);
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void Free(IntPtr pointer);
 IntPtr module; Call call; Free free;
 public L1Ffi(string path) { module=NativeLibrary.Load(path); call=Marshal.GetDelegateForFunctionPointer<Call>(NativeLibrary.GetExport(module,"launcher_call")); free=Marshal.GetDelegateForFunctionPointer<Free>(NativeLibrary.GetExport(module,"launcher_free")); if(Marshal.GetDelegateForFunctionPointer<Abi>(NativeLibrary.GetExport(module,"launcher_abi_version"))()!=1) throw new Exception("ABI mismatch"); }
 public string Invoke(string request) { var input=Marshal.StringToCoTaskMemUTF8(request); IntPtr output=IntPtr.Zero; try {output=call(input);return Marshal.PtrToStringUTF8(output);} finally {if(output!=IntPtr.Zero)free(output);Marshal.FreeCoTaskMem(input);} }
 public void Dispose(){if(module!=IntPtr.Zero){NativeLibrary.Free(module);module=IntPtr.Zero;}}
}
'@
 $ffi=[L1Ffi]::new($NativeLibrary)
 function Invoke-Call([string]$command,$payload){return $ffi.Invoke((@{version=1;command=$command;payload=$payload}|ConvertTo-Json -Depth 12 -Compress))|ConvertFrom-Json}
 function Poll([string]$path){$r=Invoke-Call 'session_metrics' @{path=$path};Assert-That $r.ok 'Synthetic session FFI succeeds';return $r.data}
 try{
  if($InjectChildStall){[Threading.Thread]::Sleep([Threading.Timeout]::Infinite)}
  $data=Poll $complete;$t=$data.last.analysis.timeline
  Assert-That ($t.version -eq 1 -and $t.coordinateKind -eq 'logged_turn_window' -and $t.boundsResolutionMs -eq 1000) 'Timeline v1 conservative coordinate contract'
  Assert-That ($t.spanMs -eq 3000 -and $data.last.durationMs -eq 2000 -and $data.last.firstTokenMs -eq 100) 'Axis window is distinct from actual duration and first model token'
  Assert-That ($t.items.Count -eq 4 -and $t.shownItems -eq 4 -and $t.omittedItems -eq 0 -and !$t.sourcePartial -and $t.coverageInterpretation -eq 'approximate') 'Complete source permits approximate coverage'
  Assert-That ((@($t.items.category|Sort-Object -Unique) -join ',') -eq 'message,other,reasoning,tool') 'All four categories cross the real DLL boundary'
  Assert-That (($t|ConvertTo-Json -Depth 15) -notmatch 'PRIVATE_|identity_content|"id"|"command"|"content"|"arguments"|"prompt"') 'Timeline excludes private content and internal IDs'
  Assert-That (@($t.items|Where-Object {!$_.drawable}).Count -eq 0 -and $t.items[0].ordinal -eq 1) 'Chronological positive contained rows are drawable'
  $data=Poll $limited;$t=$data.last.analysis.timeline
  Assert-That ($t.totalItems -eq 205 -and $t.shownItems -eq 200 -and $t.items.Count -eq 200 -and $t.omittedItems -eq 5) 'Only chronological first 200 of 205 rows displayed'
  Assert-That ($t.items[199].ordinal -eq 200 -and $t.coverageInterpretation -eq 'unavailable') 'Omitted rows cannot be interpreted as empty waiting'
  Assert-That ($data.last.analysis.observedMs -eq 1120) 'H2 observed union includes all 205 rows beyond the display cap'
  $data=Poll $partial;$t=$data.last.analysis.timeline
  Assert-That ($t.sourcePartial -and $t.coverageInterpretation -eq 'unavailable') 'Incomplete history disables numerical gap interpretation'
  $data=Poll $invalid;$t=$data.last.analysis.timeline
  Assert-That ($t.items.Count -eq 4 -and @($t.items|Where-Object drawable).Count -eq 0) 'Zero, reversed, missing and outside rows remain facts without bars'
  $reasons=@($t.items|ForEach-Object {$_.reasons})
  Assert-That ($reasons -contains 'zero_duration' -and $reasons -contains 'reversed' -and $reasons -contains 'missing_start' -and $reasons -contains 'outside_bounds') 'Invalid intervals carry explicit safe reason codes'
  $reject=Invoke-Call 'benchmark_start' @{mode='local_replay';protocol='chat_completions';baseUrl='https://example.com/v1';model='fixture-model';prompt='SYNTHETIC_ONLY';resolvedProxy='DIRECT';timeoutMs=1000;idleTimeoutMs=500}
  Assert-That (!$reject.ok) 'Existing M2 local replay rejects an external URL before network work'
  foreach($entry in $fixtureBefore){Assert-That ((Get-Item -LiteralPath $entry.path).IsReadOnly -and (Get-FileHash -LiteralPath $entry.path).Hash -eq $entry.hash) 'Synthetic source remains read-only and unchanged'}
 }finally{$ffi.Dispose()}
 Write-Json @{stage='L1';checks=$checks.ToArray();dllSha256=(Get-FileHash -LiteralPath $NativeLibrary).Hash;syntheticHome=$fixtureHome;liveApiRequests=0;realSessionReads=0} $ReceiptPath
 return
}
$directory=Join-Path $root ('environment/stage-l1-validation-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory|Out-Null
$receipt=Join-Path $directory 'ffi.json'
$owned=[Collections.Generic.List[object]]::new();$failure=$null;$forcedCleanup=$false;$runtimeExe='';$child=$null
function Compare-Preservation {
 $hashes=@(foreach($kind in @('installed','packages','m2files')){foreach($entry in @(Read-Json (Join-Path $root "environment/l1-before-$kind.json"))){
  $actual=if(Test-Path -LiteralPath $entry.Path -PathType Leaf){(Get-FileHash -LiteralPath $entry.Path).Hash}else{''}
  [ordered]@{path=$entry.Path;expected=$entry.Hash;actual=$actual;unchanged=($actual -eq $entry.Hash)}
 }})
 $processes=@(foreach($entry in @(Read-Json (Join-Path $root 'environment/l1-before-processes.json'))){
  $p=Get-Process -Id $entry.id -ErrorAction SilentlyContinue
  [ordered]@{id=$entry.id;path=$entry.path;startedUtcTicks=$entry.startedUtcTicks;preserved=($null -ne $p -and $p.Path -eq $entry.path -and $p.StartTime.ToUniversalTime().Ticks -eq $entry.startedUtcTicks)}
 })
 return @{hashes=$hashes;processes=$processes}
}
function Assert-Preservation($value){
 Assert-That ($value.hashes.Count -eq 22 -and @($value.hashes|Where-Object {!$_.unchanged}).Count -eq 0) 'All 22 protected L1 file hashes preserved'
 Assert-That ($value.processes.Count -eq 15 -and @($value.processes|Where-Object {!$_.preserved}).Count -eq 0) 'All 15 baseline process IDs, paths and UTC ticks preserved'
}
function Start-Exact([string]$exe,[string[]]$arguments,[string]$logPrefix=''){
 $opts=@{FilePath=$exe;ArgumentList=$arguments;WindowStyle='Hidden';PassThru=$true}
 if($logPrefix){$opts.RedirectStandardOutput="$logPrefix.stdout.txt";$opts.RedirectStandardError="$logPrefix.stderr.txt"}
 $p=Start-Process @opts
 $identity=@{handle=$p;id=$p.Id;path=[IO.Path]::GetFullPath($exe);startedUtcTicks=$p.StartTime.ToUniversalTime().Ticks}
 $owned.Add($identity)
 return $p
}
function Wait-Exit($p,[int]$milliseconds,[string]$message){if(!$p.WaitForExit($milliseconds) -or $p.ExitCode -ne 0){throw $message}}
function Stop-Runtime {
 if(!$runtimeExe){return}
 $live=@($owned|Where-Object {$_.path -eq $runtimeExe -and !$_.handle.HasExited})
 if($live.Count){$stop=Start-Exact $runtimeExe @('--isolated-instance','--monitor-exit');Wait-Exit $stop 15000 'Explicit isolated stop failed';foreach($entry in $live){Wait-Exit $entry.handle 30000 'Owned runtime did not exit normally'}}
}
function Cleanup-Exact {
 $cleanupErrors=[Collections.Generic.List[string]]::new()
 foreach($entry in $owned){
  try{
   $p=$entry.handle
   if($p.HasExited){continue}
   $current=Get-Process -Id $entry.id -ErrorAction SilentlyContinue
   if($null -eq $current -or $current.Path -ne $entry.path -or $current.StartTime.ToUniversalTime().Ticks -ne $entry.startedUtcTicks){throw 'Exact owned identity mismatch; no termination attempted'}
   $null=$p.CloseMainWindow()
   if(!$p.WaitForExit(500)){$p.Kill();$script:forcedCleanup=$true;if(!$p.WaitForExit(2000)){throw 'Exact owned process cleanup timed out'}}
  }catch{$cleanupErrors.Add($_.ToString())}
 }
 if($cleanupErrors.Count){throw ($cleanupErrors -join '; ')}
}
try{
 foreach($kind in @('installed','packages','m2files','processes')){Assert-That ((@(Read-Json (Join-Path $root "environment/l1-before-$kind.json"))).Count -gt 0) "Original nonempty L1 baseline: $kind"}
 $before=Compare-Preservation;Write-Json $before (Join-Path $directory 'preservation-before.json');Assert-Preservation $before
 if($VerifiedFfiReceipt){
  if($InjectChildStall){throw 'Fault injection requires a fresh child'}
  $verified=Read-Json $VerifiedFfiReceipt
  Assert-That ($verified.stage -eq 'L1' -and $verified.checks.Count -ge 16 -and $verified.dllSha256 -eq (Get-FileHash -LiteralPath $NativeLibrary).Hash) 'Prior synthetic DLL receipt matches the exact staged core'
 }else{
  $pwsh=(Get-Process -Id $PID).Path
  $childArguments=@('-NoLogo','-NoProfile','-File',('"'+$PSCommandPath+'"'),'-FfiChild','-NativeLibrary',('"'+$NativeLibrary+'"'),'-ReceiptPath',('"'+$receipt+'"'))
  if($InjectChildStall){$childArguments+='-InjectChildStall'}
  $child=Start-Exact $pwsh $childArguments (Join-Path $directory 'ffi-child')
  Wait-Exit $child 30000 'Owned DLL smoke child failed or timed out; inspect child logs'
  Assert-That ((Read-Json $receipt).checks.Count -ge 16) 'Fresh DLL smoke child completed contract checks'
 }
 if(!$FfiOnly){
  $runtime=Join-Path $directory 'runtime';$prefix=$runtime+[IO.Path]::DirectorySeparatorChar
  if($Archive){
   $Archive=(Resolve-Path -LiteralPath $Archive).Path
   $digest=(Get-Content -LiteralPath "$Archive.sha256" -Raw).Trim() -split '\s+',2
   Assert-That ($digest.Count -eq 2 -and $digest[1] -eq [IO.Path]::GetFileName($Archive) -and (Get-FileHash -LiteralPath $Archive).Hash -eq $digest[0]) 'Immutable archive checksum matches'
   $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
   try{
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in $zip.Entries){
     $name=$entry.FullName.Replace('\','/');$target=[IO.Path]::GetFullPath((Join-Path $runtime $name))
     if([IO.Path]::IsPathRooted($name) -or $name.Split('/') -contains '..' -or !$target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or !$names.Add($name)){throw 'Unsafe or duplicate ZIP entry'}
     if([IO.Path]::GetFileName($name) -match '^(settings\.json|monitor-preferences.*|session-selection.*|pet-position.*|context.*|auth\.json)$|\.(log|pdb|jsonl)$'){throw 'Private/runtime archive entry'}
    }
   }finally{$zip.Dispose()}
   [IO.Compression.ZipFile]::ExtractToDirectory($Archive,$runtime)
   $covered=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
   foreach($item in @(Read-Json (Join-Path $runtime 'FILES-SHA256.json'))){
    $target=[IO.Path]::GetFullPath((Join-Path $runtime $item.path))
    if(!$target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or !$covered.Add($item.path)){throw 'Unsafe or duplicate manifest entry'}
    Assert-That ((Get-Item -LiteralPath $target).Length -eq $item.bytes -and (Get-FileHash -LiteralPath $target).Hash -eq $item.sha256) "Manifest integrity: $($item.path)"
   }
   foreach($file in Get-ChildItem -LiteralPath $runtime -Recurse -File){$relative=[IO.Path]::GetRelativePath($runtime,$file.FullName).Replace('\','/');if($relative -ne 'FILES-SHA256.json' -and !$covered.Contains($relative)){throw 'Uncovered archive file'}}
   $build=Read-Json (Join-Path $runtime 'BUILD-INFO.json')
   Assert-That ($build.stage -eq 'L1' -and $build.sourceCommit -match '^[0-9a-f]{40}$' -and $build.appVersion -eq '0.2.4-rc.7+11') 'Candidate declares L1 version and exact source commit'
   foreach($required in @('codex_timezone.exe','codex_timezone_core.dll','flutter_windows.dll','data/app.so','Start-Trial.cmd','Stop-Trial.cmd','STAGE-L1.md','THIRD_PARTY_NOTICES.md','licenses/AIPerf-Apache-2.0.txt','licenses/Win-CodexBar-MIT.txt','licenses/ccusage-MIT.txt')){Assert-That ($covered.Contains($required)) "Required candidate input: $required"}
   Assert-That ($build.exeSha256 -eq (Get-FileHash -LiteralPath (Join-Path $runtime 'codex_timezone.exe')).Hash -and $build.coreSha256 -eq (Get-FileHash -LiteralPath $NativeLibrary).Hash) 'Candidate runtime hashes match build identity and new L1 DLL'
   Assert-That ((Get-Content -LiteralPath (Join-Path $runtime 'Start-Trial.cmd') -Raw) -match '--isolated-instance' -and (Get-Content -LiteralPath (Join-Path $runtime 'Start-Trial.cmd') -Raw) -notmatch '--desktop-monitor') 'User trial entry opens normal isolated main window'
   Assert-That ((Get-Content -LiteralPath (Join-Path $runtime 'Stop-Trial.cmd') -Raw) -match '--isolated-instance --monitor-exit') 'Trial stop explicitly exits its isolated owner'
  }else{
   if(!$RuntimeDirectory){throw 'Supply RuntimeDirectory or Archive, or use FfiOnly'}
   $source=(Resolve-Path -LiteralPath $RuntimeDirectory).Path
   New-Item -ItemType Directory -Path $runtime|Out-Null
   foreach($file in Get-ChildItem -LiteralPath $source -Recurse -File){
    $relative=[IO.Path]::GetRelativePath($source,$file.FullName).Replace('\','/')
    if($relative -eq 'codex_timezone.exe' -or $relative -match '^[^/]+\.dll$' -or $relative -eq 'native_assets.json' -or $relative -match '^data/(flutter_assets/|icudtl\.dat$|app\.so$)'){$target=Join-Path $runtime $relative;New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force|Out-Null;Copy-Item -LiteralPath $file.FullName -Destination $target}
   }
   Copy-Item -LiteralPath $NativeLibrary -Destination (Join-Path $runtime 'codex_timezone_core.dll') -Force
  }
  Assert-That ((Get-FileHash -LiteralPath (Join-Path $runtime 'codex_timezone_core.dll')).Hash -eq (Get-FileHash -LiteralPath $NativeLibrary).Hash) 'Restored runtime uses exact newly staged L1 core'
  $runtimeExe=Join-Path $runtime 'codex_timezone.exe';$report=Join-Path $directory 'workspace-report.json'
  $fixtureHome=Join-Path $directory 'runtime-home';$session=Write-Fixture $fixtureHome 'runtime'
  Write-Json @{version=1;enabled=$false;sessionAlerts=$true;visible=$true;mode=1} (Join-Path $runtime 'monitor-preferences-v1.json')
  Write-Json @{version=1;path=$session;id='session'} (Join-Path $runtime 'session-selection-v1.json')
  $oldHome=$env:CODEX_HOME;$oldLibrary=$env:CODEX_TZ_NATIVE_LIBRARY
  function Wait-State([scriptblock]$condition,[string]$description){
   $deadline=[DateTime]::UtcNow.AddSeconds(35)
   do{Start-Sleep -Milliseconds 250;try{$script:last=Read-Json $report}catch{$script:last=$null};if($script:last -and (& $condition $script:last)){return}}while([DateTime]::UtcNow -lt $deadline)
   throw "Runtime state not observed: $description"
  }
  function Control([string]$action){$p=Start-Exact $runtimeExe @('--isolated-instance',"--workspace-test-action=$action");Wait-Exit $p 15000 "Injected control failed: $action"}
  try{
   $env:CODEX_HOME=$fixtureHome;$env:CODEX_TZ_NATIVE_LIBRARY=Join-Path $runtime 'codex_timezone_core.dll'
   $p=Start-Exact $runtimeExe @('--isolated-instance','--monitor-test-controls',"--monitor-report=$report")
   # Hidden automation startup may inherit SW_HIDE. Restore through the existing
   # injected control only after the bridge/collector are ready.
   Wait-State {param($v) $v.tray -and $v.bridgeReady -and $v.workspace -eq 'launcher' -and $v.sessionStatus -eq 2} 'selected synthetic history on default launcher'
   Write-Json $script:last (Join-Path $directory 'runtime-initialized.json')
   Control 'restore';Wait-State {param($v) $v.mainVisible -and $v.workspace -eq 'launcher' -and $v.sessionStatus -eq 2} 'injected restore opens initialized main window'
   Assert-That ($script:last.petPaused -and !$script:last.visible -and $script:last.attempts -eq 0 -and $script:last.notificationAttempts -eq 0) 'Pet paused, history silent, zero quota calls'
   Write-Json $script:last (Join-Path $directory 'runtime-restored.json')
   Control 'close';Wait-State {param($v) !$v.mainVisible -and $v.keepAlive} 'selected collector survives close'
   Write-Json $script:last (Join-Path $directory 'runtime-after-close.json')
   Control 'restore';Wait-State {param($v) $v.mainVisible -and $v.sessionStatus -eq 2} 'same selected collector restores'
   Control 'legacy-show';Control 'resume';Wait-State {param($v) $v.petPaused -and !$v.visible} 'pet remains paused under legacy controls'
   Assert-That ($script:last.pid -eq $p.Id -and $script:last.attempts -eq 0 -and $script:last.sessionAlertsShown -eq 0) 'Same owned process, zero quota calls and no history completion notices retained'
   Assert-That ($script:last.backgroundNotices -eq 1 -and $script:last.notificationAttempts -eq 1 -and $script:last.notificationKind -eq 'background') 'Existing first-close background notice is distinct from a session completion replay'
   Write-Json $script:last (Join-Path $directory 'runtime-retained.json')
  }finally{try{Stop-Runtime}finally{$env:CODEX_HOME=$oldHome;$env:CODEX_TZ_NATIVE_LIBRARY=$oldLibrary}}
 }
}catch{$failure=$_.ToString()}
finally{
 try{Stop-Runtime}catch{if($failure){$failure+='; normal exit: '+$_.ToString()}else{$failure=$_.ToString()}}
 try{Cleanup-Exact}catch{if($failure){$failure+='; cleanup: '+$_.ToString()}else{$failure=$_.ToString()}}
 try{$after=Compare-Preservation;Write-Json $after (Join-Path $directory 'preservation-after.json');Assert-Preservation $after}catch{if($failure){$failure+='; preservation: '+$_.ToString()}else{$failure=$_.ToString()}}
 $remaining=@($owned|Where-Object {!$_.handle.HasExited}).Count
 if($remaining -and !$failure){$failure='Owned process remains'}
 $identities=@($owned|ForEach-Object {[ordered]@{id=$_.id;path=$_.path;startedUtcTicks=$_.startedUtcTicks;exited=$_.handle.HasExited}})
 Write-Json @{passed=(!$failure);failure=$failure;checks=$checks.ToArray();directory=$directory;forcedCleanup=$forcedCleanup;ownedProcessesRemaining=$remaining;ownedProcessIdentities=$identities;verifiedFfiReceipt=$VerifiedFfiReceipt;stagedCoreSha256=(Get-FileHash -LiteralPath $NativeLibrary).Hash;physicalChartLayout='NOT_RUN';physicalMouseNavigation='NOT_RUN';physicalNotificationDisplay='NOT_RUN';physicalNotificationClick='NOT_RUN';source='read-only synthetic logs and injected native controls';liveApiRequests=0;realSessionReads=0} (Join-Path $directory 'ACCEPTANCE.json')
}
if($failure){throw "$failure; evidence: $directory"}
Write-Output "PASS: $($checks.Count) parent assertions; evidence: $directory"
