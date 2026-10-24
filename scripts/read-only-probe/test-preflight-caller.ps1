$ErrorActionPreference='Stop'
# Exercise the actual caller function with a deterministic child object. No
# native process, official CLI, auth directory, or network is used by this test.
Add-Type -TypeDefinition @'
namespace K32Probe {
 public sealed class CallerChild {
  public sealed class Token { public int Pid { get { return 2147483647; } } }
  public sealed class Receipt { public bool Confirmed; }
  public Token Identity = new Token();
  public bool CreatedSuspended = true, JobAssignedBeforeResume = true;
  public int InheritedHandleCount = 3;
  public bool Stopped, Disposed;
  public Receipt Stop(Token token, int milliseconds) {
   Stopped = true;
   if (OwnedStdioChild.Mode == "throw") throw new System.InvalidOperationException("synthetic_stop_failure");
   return new Receipt { Confirmed = OwnedStdioChild.Mode != "unconfirmed" };
  }
  public void Dispose() { Disposed = true; }
 }
 public static class OwnedStdioChild {
  public static string Mode = "confirmed";
  public static CallerChild Last;
  public static CallerChild Start(string exe, string[] args, string cwd, object env) { return Last = new CallerChild(); }
 }
}
'@
$parseErrors=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'run-official-preflight.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'caller_parse_failed'}
$blocked=& (Join-Path $PSScriptRoot 'run-official-preflight.ps1') | ConvertFrom-Json
if($blocked.status -cne 'blocked' -or $blocked.reasonCode -cne 'startup_auth_backend_unverified' -or $blocked.processesStarted -ne 0 -or $null -ne [K32Probe.OwnedStdioChild]::Last){throw 'unverified_startup_must_not_launch'}
$script:checks+=4
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-OwnStep'},$true)
Invoke-Expression $function.Extent.Text
$cli=$PSCommandPath;$cliHash=(Get-FileHash -LiteralPath $cli -Algorithm SHA256).Hash
$workspace=$PSScriptRoot;$envChild=@{}
function Get-Process { throw 'synthetic_metadata_unavailable' }
$checks=4
function Assert($condition,[string]$label){if(!$condition){throw ('assertion_failed:'+ $label)};$script:checks++}
$directoryFunction=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-PlainDirectory'},$true)
Invoke-Expression $directoryFunction.Extent.Text
$validDirectory=$true
try{Assert-PlainDirectory $PSScriptRoot}catch{$validDirectory=$false}
Assert $validDirectory 'real_directory_and_ancestors_accepted'
$fileRejected=$false
try{Assert-PlainDirectory $PSCommandPath}catch{$fileRejected=$true}
Assert $fileRejected 'file_is_not_directory'
foreach($mode in @('confirmed','unconfirmed','throw')){
  [K32Probe.OwnedStdioChild]::Mode=$mode
  $processes=[Collections.Generic.List[object]]::new()
  $actionRan=$false;$caught=$false
  try{Invoke-OwnStep 'synthetic' @() {$script:actionRan=$true}}catch{$caught=$true}
  Assert ($processes.Count -eq 1) ($mode+':child_registered')
  Assert $actionRan ($mode+':metadata_failure_does_not_skip_action')
  Assert ([K32Probe.OwnedStdioChild]::Last.Stopped) ($mode+':stop_attempted')
  if($mode -ceq 'confirmed'){
    Assert (!$caught -and $processes[0].cleanupConfirmed) 'confirmed:receipt'
    Assert ([K32Probe.OwnedStdioChild]::Last.Disposed) 'confirmed:dispose_after_confirmation'
  }else{
    Assert ($caught -and !$processes[0].cleanupConfirmed) ($mode+':uncertainty_preserved')
    Assert (![K32Probe.OwnedStdioChild]::Last.Disposed) ($mode+':no_premature_dispose')
  }
}
"PASS $checks caller lifecycle assertions; no processes launched"
