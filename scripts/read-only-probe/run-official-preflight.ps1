param([string]$EvidenceDirectory='')
$ErrorActionPreference='Stop'
function Get-K32OfficialStartupCapability {
  # The same-version startup/policy path has been audited. The actual effective
  # backend and identity probe remain incomplete; this offline change preserves
  # the prior no-start state, without an override or retry fallback.
  [pscustomobject]@{supported=$false;reasonCode='startup_auth_backend_unverified'}
}
function Get-K32ReadonlyArguments {
  # Future launch template only; the public entry still returns before any use.
  @('--no-daemon','-c','cli_auth_credentials_store="file"','-c','analytics.enabled=false','app-server','--strict-config','--listen','stdio://')
}
$startupCapability=Get-K32OfficialStartupCapability
if(!$startupCapability.supported){
  [ordered]@{status='blocked';reasonCode=$startupCapability.reasonCode;processesStarted=0;accountReads=0;realModelRequests=$false;authenticatedContinuityVerified=$false}|ConvertTo-Json
  return
}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if(!$EvidenceDirectory){$EvidenceDirectory=Join-Path $repo 'environment/k3-2-readonly-validation-20261025-a'}
$EvidenceDirectory=[IO.Path]::GetFullPath($EvidenceDirectory)
$allowed=[IO.Path]::GetFullPath((Join-Path $repo 'environment')).TrimEnd('\')+'\'
if(!$EvidenceDirectory.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'evidence_outside_workspace'}
function Assert-PlainDirectory([string]$Path){
  $item=Get-Item -LiteralPath $Path
  while($item){
    if(!($item.Attributes -band [IO.FileAttributes]::Directory) -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'reparse_or_invalid_directory'}
    $item=$item.Parent
  }
}
Assert-PlainDirectory $EvidenceDirectory
$helper=Join-Path $PSScriptRoot 'OwnedStdioChild.cs'
if((Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash -ne '134B8AFD7D5861FE912980AA6FD5D5AE7B9ABB8EEC387D8A61AD57C674D451A1'){throw 'helper_not_reviewed'}
Add-Type -Path $helper
Import-Module (Join-Path $PSScriptRoot 'ReadOnlyProtocol.psm1') -Force
$pin=Get-Content -LiteralPath (Join-Path $repo 'environment/k3-1-isolation-validation-20261025-a/cli-static/executable-receipt.json') -Raw|ConvertFrom-Json
$cli=(Get-Command codex.exe -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
if(![string]::Equals([IO.Path]::GetFullPath($cli),[IO.Path]::GetFullPath($pin.path),[StringComparison]::OrdinalIgnoreCase)){throw 'cli_pin_changed'}
$cliHash=(Get-FileHash -LiteralPath $cli -Algorithm SHA256).Hash
$signature=Get-AuthenticodeSignature -LiteralPath $cli
if($cliHash -ne $pin.sha256 -or $signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'OpenAI OpCo'){throw 'cli_pin_invalid'}

$run=Join-Path $EvidenceDirectory ('official-'+[guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $run){throw 'run_already_exists'}
New-Item -ItemType Directory -Path $run|Out-Null
# Only this freshly created tree receives an ACL; no existing profile is changed.
$acl=New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
$user=[Security.Principal.WindowsIdentity]::GetCurrent().User
$acl.SetOwner($user)
$inherit=[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
foreach($sid in @($user,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))){
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
}
Set-Acl -LiteralPath $run -AclObject $acl
Set-Content -LiteralPath (Join-Path $run '.k32-owner') -Value 'codex_timezone_readonly_preflight_v1' -Encoding utf8
$probeHome=Join-Path $run 'home'; $workspace=Join-Path $run 'workspace'; $profile=Join-Path $run 'profile'; $temp=Join-Path $run 'temp'
foreach($path in @($probeHome,$workspace,$profile,$temp,(Join-Path $profile 'appdata'),(Join-Path $profile 'localappdata'))){
  New-Item -ItemType Directory -Path $path|Out-Null
  Assert-PlainDirectory $path
}
if(@(Get-ChildItem -LiteralPath $probeHome -Force).Count){throw 'home_not_empty'}
$envChild=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($pair in @{
  CODEX_HOME=$probeHome; HOME=$profile; USERPROFILE=$profile; APPDATA=(Join-Path $profile 'appdata'); LOCALAPPDATA=(Join-Path $profile 'localappdata');
  TEMP=$temp; TMP=$temp; SystemRoot=$env:SystemRoot; WINDIR=$env:SystemRoot; COMSPEC=(Join-Path $env:SystemRoot 'System32/cmd.exe'); PATH=(Join-Path $env:SystemRoot 'System32')
}.GetEnumerator()){$envChild.Add([string]$pair.Key,[string]$pair.Value)}
$readonlyArgs=Get-K32ReadonlyArguments
$lease=[IO.FileStream]::new((Join-Path $run '.home-lease'),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$processes=[Collections.Generic.List[object]]::new()
$observations=[Collections.Generic.List[object]]::new()
$fatal=$null

function Get-SafeTransportCode($ErrorRecord){
  $ex=$ErrorRecord.Exception
  while($ex){
    if($ex -is [K32Probe.ProbeException]){return $ex.ReasonCode}
    if($ex.Message -cin @('unexpected_credential_file','cleanup_unconfirmed','malformed_response','cli_pin_changed')){return $ex.Message}
    $ex=$ex.InnerException
  }
  return 'probe_incomplete'
}
function Invoke-OwnStep([string]$Kind,[string[]]$Arguments,[scriptblock]$Action){
  $child=$null; $record=$null
  try{
    if((Get-FileHash -LiteralPath $cli -Algorithm SHA256).Hash -ne $cliHash){throw 'cli_pin_changed'}
    $child=[K32Probe.OwnedStdioChild]::Start($cli,$Arguments,$workspace,$envChild)
    # Establish fail-closed cleanup bookkeeping before optional process metadata.
    # A short-lived child may already have exited when Get-Process runs.
    $record=[ordered]@{kind=$Kind;pid=$child.Identity.Pid;startUtcTicks=$null;createdSuspended=$child.CreatedSuspended;jobBeforeResume=$child.JobAssignedBeforeResume;inheritedHandles=$child.InheritedHandleCount;cleanupConfirmed=$false}
    $processes.Add($record)
    try{$record.startUtcTicks=(Get-Process -Id $child.Identity.Pid -ErrorAction Stop).StartTime.ToUniversalTime().Ticks}catch{}
    & $Action $child
  }finally{
    if($child){
      $cleanup=$child.Stop($child.Identity,5000)
      $record.cleanupConfirmed=$cleanup.Confirmed
      if(!$cleanup.Confirmed){throw 'cleanup_unconfirmed'}
      $child.Dispose()
    }
  }
}
try{
  for($round=1;$round -le 2;$round++){
    if(Test-Path -LiteralPath (Join-Path $probeHome 'auth.json')){throw 'unexpected_credential_file'}
    Invoke-OwnStep ('readonly_session_'+$round) $readonlyArgs {
      param($child)
      $projection=Invoke-K32ReadonlyHandshake -Child $child -ExpectedHome $probeHome -Workspace $workspace -TimeoutMs 20000 -ExpectUnauthenticated
      $observations.Add($projection)
    }
    # A config/home/protocol failure cannot be followed by another attempt that
    # might downgrade the gate. No alternate binary/account/home fallback.
    if($observations[$observations.Count-1].status -ceq 'failed'){break}
  }
}catch{$fatal=Get-SafeTransportCode $_}
finally{
  $uncertain=(@($processes|Where-Object {!$_.cleanupConfirmed}).Count -gt 0 -or $fatal -ceq 'start_cleanup_unconfirmed')
  if($uncertain){
    # Keep this exact lease rooted for the diagnostic host lifetime. An
    # unconfirmed child must not permit another writer to this new home.
    [AppDomain]::CurrentDomain.SetData(('K32ProbeUnconfirmedLease:'+ $run),$lease)
  }else{$lease.Dispose()}
  $hashAfter=$null
  try{$hashAfter=(Get-FileHash -LiteralPath $cli -Algorithm SHA256).Hash}catch{$fatal='cli_pin_changed'}
  if($hashAfter -ne $cliHash){$fatal='cli_pin_changed'}
  $receipt=[ordered]@{
    utc=[DateTime]::UtcNow.ToString('o');sourceCommit=[string](& git -C $repo rev-parse HEAD);runDirectory=$run;
    cliSha256=$cliHash.ToLowerInvariant();cliUnchanged=($hashAfter -eq $cliHash);cliSignatureValid=$true;
    helperSha256=(Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant();
    protocolSha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'ReadOnlyProtocol.psm1') -Algorithm SHA256).Hash.ToLowerInvariant();
    childEnvironmentKeys=@($envChild.Keys|Sort-Object);parentEnvironmentModified=$false;homeInitiallyEmpty=$true;
    authFilePresentAfter=(Test-Path -LiteralPath (Join-Path $probeHome 'auth.json'));
    observations=$observations.ToArray();processes=$processes.ToArray();fatalReason=$fatal;
    cleanupUncertain=$uncertain;realModelRequests=$false;loginRequests=$false;realExecutionSupported=$false;authenticatedContinuityVerified=$false
  }
  $receipt|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $run 'OFFICIAL-READONLY-RECEIPT.json') -Encoding utf8
  [ordered]@{runDirectory=$run;status=if($fatal){'incomplete'}elseif($observations.Count){$observations[$observations.Count-1].status}else{'no_service_probe'};fatalReason=$fatal;observationCount=$observations.Count;allCleanupConfirmed=(!$uncertain);authFilePresentAfter=$receipt.authFilePresentAfter}|ConvertTo-Json
}
