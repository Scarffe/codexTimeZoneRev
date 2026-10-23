param([string]$NativeLibrary='', [switch]$ReplayChild, [string]$ReceiptPath='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$fresh=Join-Path $root 'environment/stage-m2-cargo/release/codex_timezone_core.dll'
if(!$NativeLibrary){$NativeLibrary=$fresh}
$NativeLibrary=(Resolve-Path -LiteralPath $NativeLibrary).Path
if($NativeLibrary -ne (Resolve-Path -LiteralPath $fresh).Path){throw 'M2 smoke requires the exact fresh stage-m2-cargo DLL'}
if(!$ReceiptPath){$ReceiptPath=Join-Path $root ('environment/stage-m2-ffi-'+[guid]::NewGuid().ToString('N')+'.json')}
if(Test-Path -LiteralPath $ReceiptPath){throw 'Do not overwrite an existing M2 receipt'}
if(!$ReplayChild){
 # Preserve the interrupted-session baseline separately. It cannot establish
 # continuity for processes that had already exited or whose PIDs were reused.
 $originalProcesses=@(Get-Content -LiteralPath (Join-Path $root 'environment/m2-before-processes.json') -Raw|ConvertFrom-Json)
 $monitoredNames=@($originalProcesses|ForEach-Object {[IO.Path]::GetFileNameWithoutExtension($_.Path)}|Sort-Object -Unique)
 $currentBefore=@(Get-Process -Name $monitoredNames -ErrorAction SilentlyContinue|ForEach-Object {
  [ordered]@{id=$_.Id;path=$_.Path;startedUtcTicks=$_.StartTime.ToUniversalTime().Ticks}
 })
 $currentBefore|ConvertTo-Json -Depth 4|Set-Content -LiteralPath "$ReceiptPath.current-before.json" -Encoding utf8
 function Compare-M2Files {
  @(foreach($kind in @('installed','packages')){
   foreach($entry in @(Get-Content -LiteralPath (Join-Path $root "environment/m2-before-$kind.json") -Raw|ConvertFrom-Json)){
    $actual=if(Test-Path -LiteralPath $entry.Path -PathType Leaf){(Get-FileHash -LiteralPath $entry.Path).Hash}else{''}
    [ordered]@{path=$entry.Path;expected=$entry.Hash;actual=$actual;unchanged=($actual -eq $entry.Hash)}
   }
  })
 }
 $beforeHashes=Compare-M2Files
 $beforeHashes|ConvertTo-Json -Depth 4|Set-Content -LiteralPath "$ReceiptPath.files-before.json" -Encoding utf8
 if(@($beforeHashes|Where-Object {!$_.unchanged}).Count){throw 'Original M2 file hashes changed before smoke; no child started'}
 $log="$ReceiptPath.stdout.txt"; $errorLog="$ReceiptPath.stderr.txt"
 $exe=(Get-Process -Id $PID).Path
 $arguments=@('-NoLogo','-NoProfile','-File',('"'+$PSCommandPath+'"'),'-ReplayChild','-NativeLibrary',('"'+$NativeLibrary+'"'),'-ReceiptPath',('"'+$ReceiptPath+'"'))
 $child=Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $errorLog
 $failure=$null
 try {
  if(!$child.WaitForExit(30000)){throw 'Owned replay child did not exit within 30s; no unrelated process touched'}
  if($child.ExitCode -ne 0){throw "Replay child failed; see $errorLog"}
 }catch{$failure=$_}
 finally {
  $hashes=Compare-M2Files
  $originalContinuity=@(foreach($entry in $originalProcesses){
   $process=Get-Process -Id $entry.Id -ErrorAction SilentlyContinue
   [ordered]@{id=$entry.Id;path=$entry.Path;started=$entry.started;preserved=($null -ne $process -and $process.Path -eq $entry.Path -and $process.StartTime.ToUniversalTime().Ticks -eq ([DateTimeOffset]$entry.started).UtcTicks)}
  })
  $processes=@(foreach($entry in $currentBefore){
   $process=Get-Process -Id $entry.id -ErrorAction SilentlyContinue
   [ordered]@{id=$entry.id;path=$entry.path;startedUtcTicks=$entry.startedUtcTicks;preserved=($null -ne $process -and $process.Path -eq $entry.path -and $process.StartTime.ToUniversalTime().Ticks -eq $entry.startedUtcTicks)}
  })
  $remaining=if($child.HasExited){0}else{1}
  [ordered]@{hashes=$hashes;currentProcesses=$processes;originalProcessContinuity=$originalContinuity;originalContinuityProven=(@($originalContinuity|Where-Object {!$_.preserved}).Count -eq 0);ownedClientProcessesRemaining=$remaining}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath "$ReceiptPath.preservation.json" -Encoding utf8
  if(@($hashes|Where-Object {!$_.unchanged}).Count -or @($processes|Where-Object {!$_.preserved}).Count -or $remaining){throw 'M2 preservation or owned-child cleanup check failed; see preservation receipt'}
 }
 if($failure){throw $failure}
 Get-Content -LiteralPath $ReceiptPath -Raw
 return
}
# Everything below runs in one dedicated child process. Fake ambient credentials
# and unreachable proxies prove that replay does not use auth/proxy discovery.
$env:OPENAI_API_KEY='M2_SYNTHETIC_NEVER_A_REAL_KEY'
$env:HTTP_PROXY='http://192.0.2.1:9';$env:HTTPS_PROXY=$env:HTTP_PROXY;$env:ALL_PROXY=$env:HTTP_PROXY;$env:NO_PROXY=''
$syntheticHome=Join-Path $root ('environment/stage-m2-ffi-home-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $syntheticHome 'sessions') -Force|Out-Null
$env:CODEX_HOME=$syntheticHome
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
public sealed class M2Ffi : IDisposable {
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate uint Abi();
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr Call(IntPtr request);
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void Free(IntPtr pointer);
 IntPtr module; Call call; Free free;
 public M2Ffi(string path) { module=NativeLibrary.Load(path); call=Marshal.GetDelegateForFunctionPointer<Call>(NativeLibrary.GetExport(module,"launcher_call")); free=Marshal.GetDelegateForFunctionPointer<Free>(NativeLibrary.GetExport(module,"launcher_free")); if(Marshal.GetDelegateForFunctionPointer<Abi>(NativeLibrary.GetExport(module,"launcher_abi_version"))()!=1) throw new Exception("ABI mismatch"); }
 public string Invoke(string request) { var input=Marshal.StringToCoTaskMemUTF8(request); IntPtr output=IntPtr.Zero; try {output=call(input);return Marshal.PtrToStringUTF8(output);} finally {if(output!=IntPtr.Zero)free(output);Marshal.FreeCoTaskMem(input);} }
 public void Dispose(){if(module!=IntPtr.Zero){NativeLibrary.Free(module);module=IntPtr.Zero;}}
}
public sealed class M2Replay : IDisposable {
 TcpListener listener; CancellationTokenSource stop=new CancellationTokenSource(); Task worker;
 public int Port; public int Accepts; public string Request=""; public bool CleanupComplete;
 public M2Replay(){listener=new TcpListener(IPAddress.Loopback,0);listener.Start();Port=((IPEndPoint)listener.LocalEndpoint).Port;worker=Task.Run(async()=>{
  try {using(var socket=await listener.AcceptTcpClientAsync(stop.Token)){Interlocked.Increment(ref Accepts);using(var stream=socket.GetStream()){
   var bytes=new MemoryStream();var buffer=new byte[4096];while(true){int n=await stream.ReadAsync(buffer,stop.Token);if(n==0)throw new Exception("request incomplete");bytes.Write(buffer,0,n);Request=Encoding.UTF8.GetString(bytes.ToArray());int end=Request.IndexOf("\r\n\r\n",StringComparison.Ordinal);if(end>=0){int size=0;foreach(var line in Request.Substring(0,end).Split("\r\n")){if(line.StartsWith("content-length:",StringComparison.OrdinalIgnoreCase))size=int.Parse(line.Substring(15).Trim());}if(bytes.Length>=end+4+size)break;}}
   string payload="data: {\"id\":\"fixture-response\",\"object\":\"chat.completion.chunk\",\"model\":\"fixture-response-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"fixture\"},\"finish_reason\":null}]}\n\n"+
    "data: {\"id\":\"fixture-response\",\"object\":\"chat.completion.chunk\",\"model\":\"fixture-response-model\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"+
    "data: {\"id\":\"fixture-response\",\"object\":\"chat.completion.chunk\",\"model\":\"fixture-response-model\",\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":1}}\n\n"+"data: [DONE]\n\n";
   var response=Encoding.UTF8.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"+payload);await stream.WriteAsync(response,stop.Token);
  }}}catch(OperationCanceledException){}finally{listener.Stop();CleanupComplete=true;}
 });}
 public void Dispose(){stop.Cancel();listener.Stop();if(!worker.Wait(2000))throw new Exception("owned fixture did not stop");stop.Dispose();}
}
'@
$checks=[Collections.Generic.List[string]]::new()
function Assert-That([bool]$condition,[string]$description){if(!$condition){throw $description};$checks.Add($description)}
$ffi=[M2Ffi]::new($NativeLibrary);$fixture=[M2Replay]::new();$runId=$null;$shutdown=$false
function Invoke-M2([string]$command,$payload){
 $response=$ffi.Invoke((@{version=1;command=$command;payload=$payload}|ConvertTo-Json -Depth 12 -Compress))|ConvertFrom-Json
 if(!$response.ok){throw "$command failed: $($response.error)"};return $response.data
}
try {
 $invalid=$ffi.Invoke('{"version":1,"command":"unknown_m2_smoke","payload":{}}')|ConvertFrom-Json
 Assert-That (!$invalid.ok -and $invalid.version -eq 1) 'Existing version-1 error envelope preserved'
 $session=Invoke-M2 'session_metrics' @{action='list'}
 Assert-That (@($session.sessions).Count -eq 0) 'Existing session command lists only the synthetic empty home'
 $start=Invoke-M2 'benchmark_start' @{mode='local_replay';protocol='chat_completions';baseUrl="http://127.0.0.1:$($fixture.Port)/v1";model='fixture-model';prompt='SYNTHETIC_M2_PROMPT';resolvedProxy='DIRECT';timeoutMs=2000;idleTimeoutMs=500}
 $runId=$start.runId;Assert-That ($start.state -eq 'queued') 'Fresh DLL accepts asynchronous replay'
 $deadline=[DateTime]::UtcNow.AddSeconds(5)
 do {$status=Invoke-M2 'benchmark_status' @{runId=$runId};if(!$status.cleanupPending){break};Start-Sleep -Milliseconds 5}while([DateTime]::UtcNow -lt $deadline)
 Assert-That ($status.state -eq 'completed' -and !$status.cleanupPending -and $status.successfulSample) 'Real EOF completes replay and worker cleanup'
 Assert-That ($status.requestedModel -eq 'fixture-model' -and $status.responseModel -eq 'fixture-response-model') 'Requested and response identities preserved'
 Assert-That ($status.metrics.e2eTokensPerSecond.quality -eq 'reported' -and $null -ne $status.metrics.e2eTokensPerSecond.value) 'Valid one-token reported E2E retained'
 Assert-That ($fixture.Accepts -eq 1 -and $fixture.Request.StartsWith('POST /v1/chat/completions HTTP/1.1')) 'One direct POST and no retries'
 Assert-That ($fixture.Request -notmatch '(?im)^Authorization:|^Proxy-Authorization:') 'No Authorization despite synthetic ambient key and proxy'
 Assert-That (($status|ConvertTo-Json -Depth 15) -notmatch 'SYNTHETIC_M2_PROMPT|M2_SYNTHETIC_NEVER_A_REAL_KEY|127\.0\.0\.1') 'No prompt, key or raw URL in snapshot'
 $result=Invoke-M2 'benchmark_shutdown' @{runId=$runId};$shutdown=$true
 Assert-That (!$result.accepting -and $result.cleanupComplete) 'Bounded shutdown acknowledges clean worker'
}finally{
 if(!$shutdown){try{Invoke-M2 'benchmark_shutdown' $(if($runId){@{runId=$runId}}else{@{}})|Out-Null}catch{}}
 try{$fixture.Dispose()}finally{$ffi.Dispose()}
}
Assert-That $fixture.CleanupComplete 'Owned loopback fixture task disposed normally'
[ordered]@{stage='M2';utc=[DateTime]::UtcNow.ToString('o');dll=$NativeLibrary;dllSha256=(Get-FileHash -LiteralPath $NativeLibrary).Hash;checks=$checks;ownedFixtureTasksRemaining=0;liveApiRequests=0}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $ReceiptPath -Encoding utf8
