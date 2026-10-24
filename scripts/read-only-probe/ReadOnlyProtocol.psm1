Set-StrictMode -Version 2.0

# A small strict decoder avoids ConvertFrom-Json's duplicate-key replacement and
# case folding. No received JSON, exception text or account values leave this module.
if (-not ('K32Readonly.StrictJson' -as [type])) {
    $jsonSource=@'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
namespace K32Readonly {
 public sealed class StrictJson {
  readonly string text; int at, tokens;
  StrictJson(string value) { text=value; }
  static Exception Bad() { return new FormatException("malformed_response"); }
  public static object Parse(string value) {
   if(value==null || value.Length>1048576) throw Bad();
   var p=new StrictJson(value); var result=p.Value(0); p.Space();
   if(p.at!=value.Length) throw Bad(); return result;
  }
  void Space() { while(at<text.Length && (text[at]==' '||text[at]=='\r'||text[at]=='\n'||text[at]=='\t')) at++; }
  bool Take(char c) { Space(); if(at<text.Length && text[at]==c) {at++;return true;} return false; }
  object Value(int depth) {
   if(depth>32 || ++tokens>100000) throw Bad(); Space(); if(at>=text.Length) throw Bad();
   char c=text[at];
   if(c=='"') return String();
   if(c=='{') {
    at++; var map=new Dictionary<string,object>(StringComparer.Ordinal);
    var keys=new Dictionary<string,bool>(StringComparer.OrdinalIgnoreCase); if(Take('}')) return map;
    do { Space(); if(at>=text.Length||text[at]!='"') throw Bad(); string key=String();
     if(keys.ContainsKey(key)||!Take(':')) throw Bad(); keys.Add(key,true); map.Add(key,Value(depth+1));
     if(Take('}')) return map;
    } while(Take(',')); throw Bad();
   }
   if(c=='[') {at++; var a=new List<object>(); if(Take(']')) return a.ToArray();
    do {a.Add(Value(depth+1)); if(Take(']')) return a.ToArray();} while(Take(',')); throw Bad();}
   if(c=='t' && Literal("true")) return true;
   if(c=='f' && Literal("false")) return false;
   if(c=='n' && Literal("null")) return null;
   int start=at; if(c=='-') at++; if(at>=text.Length) throw Bad();
   if(text[at]=='0') at++; else {if(text[at]<'1'||text[at]>'9') throw Bad(); while(at<text.Length && text[at]>='0'&&text[at]<='9') at++;}
   bool integral=true;
   if(at<text.Length && text[at]=='.') {integral=false; at++; int digits=at; while(at<text.Length&&text[at]>='0'&&text[at]<='9') at++; if(at==digits) throw Bad();}
   if(at<text.Length&&(text[at]=='e'||text[at]=='E')) {integral=false;at++; if(at<text.Length&&(text[at]=='+'||text[at]=='-')) at++; int digits=at; while(at<text.Length&&text[at]>='0'&&text[at]<='9') at++; if(at==digits) throw Bad();}
   string number=text.Substring(start,at-start); long integer; double real;
   if(integral && Int64.TryParse(number,NumberStyles.AllowLeadingSign,CultureInfo.InvariantCulture,out integer)) return integer;
   if(!Double.TryParse(number,NumberStyles.Float,CultureInfo.InvariantCulture,out real)||Double.IsNaN(real)||Double.IsInfinity(real)) throw Bad();
   return real;
  }
  bool Literal(string value) {if(at+value.Length>text.Length || System.String.CompareOrdinal(text,at,value,0,value.Length)!=0) throw Bad();at+=value.Length;return true;}
  string String() {
   if(text[at++]!='"') throw Bad();var b=new StringBuilder();
   while(at<text.Length) {char c=text[at++]; if(c=='"') {
     string result=b.ToString(); for(int i=0;i<result.Length;i++) {if(Char.IsHighSurrogate(result[i])) {if(++i>=result.Length||!Char.IsLowSurrogate(result[i])) throw Bad();} else if(Char.IsLowSurrogate(result[i])) throw Bad();} return result;
    }
    if(c<32) throw Bad(); if(c!='\\') {b.Append(c);continue;} if(at>=text.Length) throw Bad();c=text[at++];
    switch(c) {case '"':b.Append('"');break;case '\\':b.Append('\\');break;case '/':b.Append('/');break;case 'b':b.Append('\b');break;case 'f':b.Append('\f');break;case 'n':b.Append('\n');break;case 'r':b.Append('\r');break;case 't':b.Append('\t');break;
     case 'u': if(at+4>text.Length) throw Bad();int code;if(!Int32.TryParse(text.Substring(at,4),NumberStyles.AllowHexSpecifier,CultureInfo.InvariantCulture,out code)) throw Bad();b.Append((char)code);at+=4;break;
     default:throw Bad();}
   } throw Bad();
  }
 }
}
'@
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        Add-Type -TypeDefinition $jsonSource | Out-Null
    } else {
        # Keep CodeDom temporary files in the owned diagnostic source directory.
        $compiler=[CodeDom.Compiler.CompilerParameters]::new()
        $compiler.GenerateInMemory=$true
        $compiler.TempFiles=[CodeDom.Compiler.TempFileCollection]::new($PSScriptRoot,$false)
        Add-Type -CompilerParameters $compiler -TypeDefinition $jsonSource | Out-Null
    }
    $jsonSource=$null
}

function Stop-K32([string]$Code) { throw [InvalidOperationException]::new($Code) }
function Has-K32Key($Value,[string]$Key) {
    ($Value -is [Collections.IDictionary]) -and $Value.ContainsKey($Key)
}
function Test-K32Keys($Value,[string[]]$Keys) {
    if ($Value -isnot [Collections.IDictionary] -or $Value.Count -ne $Keys.Count) { return $false }
    foreach($key in $Keys) { if (!(Has-K32Key $Value $key)) { return $false } }
    return $true
}
function Get-K32JsonKind($Value,[bool]$Present=$true) {
    if (!$Present) { return 'missing' }
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [Collections.IDictionary]) { return 'object' }
    if ($Value -is [array]) { return 'array' }
    if ($Value -is [string]) { return 'string' }
    if ($Value -is [bool]) { return 'boolean' }
    if ($Value -is [long] -or $Value -is [double]) { return 'number' }
    'unavailable'
}
function Get-K32FrameShape($Frame,[bool]$Parsed=$true) {
    # Only fixed field names, JSON-kind enums and presence booleans leave here.
    $shape=[ordered]@{topLevelKind='unavailable';idKind='unavailable';resultKind='unavailable';errorKind='unavailable';methodKind='unavailable';requirementsKind='unavailable';configKind='unavailable';originsKind='unavailable';storeConstraintKind='unavailable';effectiveStoreKind='unavailable';accountKind='unavailable';requiresOpenaiAuthKind='unavailable';unknownTopLevelKeyPresent=$false}
    if (!$Parsed) { return $shape }
    $shape.topLevelKind=Get-K32JsonKind $Frame
    foreach($key in @('id','result','error','method')) {
        $present=Has-K32Key $Frame $key
        $value=$null; if ($present) { $value=$Frame[$key] }
        $shape[$key+'Kind']=Get-K32JsonKind $value $present
    }
    if ($Frame -is [Collections.IDictionary]) {
        foreach($key in $Frame.Keys) {
            if ($key -cnotin @('id','result','error','method','params')) { $shape.unknownTopLevelKeyPresent=$true }
        }
    }
    $body=$null; if (Has-K32Key $Frame 'result') { $body=$Frame.result }
    foreach($key in @('requirements','config','origins','account','requiresOpenaiAuth')) {
        $present=Has-K32Key $body $key
        $value=$null; if ($present) { $value=$body[$key] }
        $shape[$key+'Kind']=Get-K32JsonKind $value $present
    }
    $requirements=$null; if (Has-K32Key $body 'requirements') { $requirements=$body.requirements }
    $present=Has-K32Key $requirements 'cliAuthCredentialsStore'
    $value=$null; if ($present) { $value=$requirements.cliAuthCredentialsStore }
    $shape.storeConstraintKind=Get-K32JsonKind $value $present
    $config=$null; if (Has-K32Key $body 'config') { $config=$body.config }
    $present=Has-K32Key $config 'cli_auth_credentials_store'
    $value=$null; if ($present) { $value=$config.cli_auth_credentials_store }
    $shape.effectiveStoreKind=Get-K32JsonKind $value $present
    $shape
}
function Set-K32Boundary($State,[string]$Boundary,$Frame,[bool]$Parsed=$false) {
    $State.Diagnostic=[ordered]@{boundary=$Boundary;shape=(Get-K32FrameShape $Frame $Parsed)}
}
function Get-K32Path([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or ![IO.Path]::IsPathRooted($Value)) { Stop-K32 'home_mismatch' }
    $resolved=Resolve-Path -LiteralPath $Value -ErrorAction Stop
    if ($resolved.Provider.Name -cne 'FileSystem') { Stop-K32 'home_mismatch' }
    $item=Get-Item -LiteralPath $resolved.Path -Force -ErrorAction Stop
    if (!$item.PSIsContainer) { Stop-K32 'home_mismatch' }
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-K32 'home_mismatch' }
        $item=$item.Parent
    }
    [IO.Path]::GetFullPath($resolved.Path).TrimEnd([char[]]@('\','/'))
}
function Send-K32Frame {
    param($Child,[string]$Method,$Params,$Id,[int]$RemainingMs,[string]$ExpectedWorkspace)
    $valid=$false
    switch -CaseSensitive -Exact ($Method) {
        'initialize' {
            $valid=(Test-K32Keys $Params @('clientInfo','capabilities')) -and $null -eq $Params.capabilities -and
                (Test-K32Keys $Params.clientInfo @('name','title','version')) -and
                $Params.clientInfo.name -ceq 'codex_timezone' -and $Params.clientInfo.title -ceq 'K3.2 read-only preflight' -and $Params.clientInfo.version -ceq 'k3.2' -and $Id -eq 1
        }
        'initialized' { $valid=(Test-K32Keys $Params @()) -and $null -eq $Id }
        'configRequirements/read' { $valid=$null -eq $Params -and $Id -eq 2 }
        'config/read' { $valid=(Test-K32Keys $Params @('includeLayers','cwd')) -and $Params.includeLayers -is [bool] -and !$Params.includeLayers -and $Params.cwd -is [string] -and [string]::Equals($Params.cwd,$ExpectedWorkspace,[StringComparison]::Ordinal) -and $Id -eq 3 }
        'account/read' { $valid=(Test-K32Keys $Params @('refreshToken')) -and $Params.refreshToken -is [bool] -and !$Params.refreshToken -and ($Id -eq 4 -or $Id -eq 5) }
    }
    if (!$valid -or $RemainingMs -le 0) { Stop-K32 'outbound_rejected' }
    $frame=[ordered]@{method=$Method;params=$Params}
    if ($null -ne $Id) { $frame.id=$Id }
    $line=$frame|ConvertTo-Json -Depth 6 -Compress
    try { $Child.WriteLine($line,$RemainingMs) | Out-Null } catch { Stop-K32 'write_failed' }
}
function Get-K32TransportReason($ErrorRecord) {
    $ex=$ErrorRecord.Exception
    while ($null -ne $ex) {
        $prop=$ex.PSObject.Properties['ReasonCode']
        if ($null -ne $prop -and $prop.Value -ceq 'read_timeout') { return 'read_timeout' }
        if ($ex.Data.Contains('ReasonCode') -and $ex.Data['ReasonCode'] -ceq 'read_timeout') { return 'read_timeout' }
        $ex=$ex.InnerException
    }
    'read_failed'
}
function Receive-K32Frame {
    param($Child,$State,[int]$TimeoutMs,[bool]$Quiet=$false)
    Set-K32Boundary $State 'transport' $null
    try { $line=$Child.ReadLine($TimeoutMs) } catch {
        if ($Quiet -and (Get-K32TransportReason $_) -ceq 'read_timeout') { return $null }
        Stop-K32 'read_failed'
    }
    if ($null -eq $line -or $line -isnot [string]) { Stop-K32 'read_failed' }
    if ($line.Length -gt 1048576) { Stop-K32 'frame_too_large' }
    Set-K32Boundary $State 'utf8' $null
    try { $bytes=[Text.UTF8Encoding]::new($false,$true).GetByteCount($line) } catch { Stop-K32 'malformed_response' }
    if ($bytes -gt 1048576) { Stop-K32 'frame_too_large' }
    $State.MessageCount++; $State.TotalBytes+=$bytes
    if ($State.MessageCount -gt 64 -or $State.TotalBytes -gt 4194304) { Stop-K32 'message_budget_exceeded' }
    Set-K32Boundary $State 'json_decode' $null
    try { $frame=[K32Readonly.StrictJson]::Parse($line) } catch { Stop-K32 'malformed_response' }
    Set-K32Boundary $State 'top_level' $frame $true
    if ($frame -isnot [Collections.IDictionary]) { Stop-K32 'malformed_response' }
    return ,$frame
}
function Read-K32Result {
    param($Child,$State,[long]$Id,$Timer,[int]$Budget,[bool]$Quiet=$false,[string]$Method='')
    while ($true) {
        $remaining=$Budget-[int]$Timer.ElapsedMilliseconds
        if ($remaining -le 0) { Stop-K32 'timeout' }
        $readWindow=$remaining
        if ($Quiet) { $readWindow=[Math]::Min(50,$remaining) }
        $frame=Receive-K32Frame -Child $Child -State $State -TimeoutMs $readWindow -Quiet $Quiet
        if ($null -eq $frame) { return $null }
        if (Has-K32Key $frame 'method') {
            $State.Diagnostic.boundary='notification_envelope'
            if (Has-K32Key $frame 'id') { Stop-K32 'unexpected_server_request' }
            if (!(Test-K32Keys $frame @('method','params')) -or $frame.method -isnot [string]) { Stop-K32 'malformed_response' }
            if ($frame.method -ceq 'account/updated' -and $State.BaselineSeen) { Stop-K32 'identity_observation_changed' }
            if ($frame.method -cnotin @('configWarning','warning','account/updated')) { Stop-K32 'unexpected_notification' }
            $State.NotificationCount++
            continue
        }
        $State.Diagnostic.boundary='response_id'
        if ($Quiet) { Stop-K32 'unexpected_response_id' }
        if (!(Has-K32Key $frame 'id') -or $frame.id -isnot [long] -or $frame.id -ne $Id) { Stop-K32 'unexpected_response_id' }
        if (Has-K32Key $frame 'error') {
            $State.Diagnostic.boundary='error_envelope'
            if (!(Test-K32Keys $frame @('id','error'))) { Stop-K32 'malformed_response' }
            Stop-K32 'rpc_error'
        }
        $State.Diagnostic.boundary='success_envelope'
        if (!(Test-K32Keys $frame @('id','result'))) { Stop-K32 'malformed_response' }
        $State.Diagnostic.boundary='method_result'
        Assert-K32MethodResult $Method $frame.result
        return ,$frame.result
    }
}
function Assert-K32MethodResult([string]$Method,$Result) {
    # A valid generic result may be null/scalar; these methods still require an
    # object. Keep the existing reasonCode while distinguishing this boundary.
    if ($Result -isnot [Collections.IDictionary]) { Stop-K32 'malformed_response' }
    switch -CaseSensitive -Exact ($Method) {
        'initialize' {
            foreach($key in @('codexHome','platformFamily','platformOs','userAgent')) {
                if (!(Has-K32Key $Result $key) -or $Result[$key] -isnot [string]) { Stop-K32 'malformed_initialize' }
            }
        }
        'configRequirements/read' {
            if ((Has-K32Key $Result 'requirements') -and $null -ne $Result.requirements -and $Result.requirements -isnot [Collections.IDictionary]) { Stop-K32 'malformed_requirements' }
        }
        'config/read' {
            if (!(Has-K32Key $Result 'config') -or $Result.config -isnot [Collections.IDictionary] -or !(Has-K32Key $Result 'origins') -or $Result.origins -isnot [Collections.IDictionary]) { Stop-K32 'malformed_config' }
        }
    }
}
function Get-K32Account($Result) {
    if (!(Has-K32Key $Result 'requiresOpenaiAuth') -or $Result.requiresOpenaiAuth -isnot [bool] -or !(Has-K32Key $Result 'account')) { Stop-K32 'malformed_account' }
    $account=$Result.account
    if ($null -eq $account) { return $null }
    if ($account -isnot [Collections.IDictionary] -or !(Has-K32Key $account 'type') -or $account.type -isnot [string]) { Stop-K32 'malformed_account' }
    if ($account.type -cne 'chatgpt') { Stop-K32 'unsupported_account_type' }
    if (!(Has-K32Key $account 'email') -or ($null -ne $account.email -and $account.email -isnot [string]) -or !(Has-K32Key $account 'planType') -or $account.planType -isnot [string]) { Stop-K32 'malformed_account' }
    if ($account.planType -cnotin @('free','go','plus','pro','prolite','promax','team','self_serve_business_prolite','self_serve_business_usage_based','business','ent26','enterprise_cbp_automation','enterprise_cbp_usage_based','enterprise','edu','edu_plus','edu_pro','sci','sci_plus','unknown')) { Stop-K32 'malformed_account' }
    # Only the declared tuple participates; unknown/private response fields are discarded.
    return ,@{type=$account.type;email=$account.email;planType=$account.planType}
}
function Invoke-K32ReadonlyHandshake {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Child,[Parameter(Mandatory)][string]$ExpectedHome,[Parameter(Mandatory)][string]$Workspace,[int]$TimeoutMs=15000,[switch]$ExpectUnauthenticated)
    $receipt=[ordered]@{
        status='failed';reasonCode=$null;diagnostic=$null;failedStage='inputs';initializeSucceeded=$false;homeMatched=$false;
        requirementsReadSucceeded=$false;requirementStorePresent=$false;requirementStoreFile=$false;
        configReadSucceeded=$false;effectiveStoreFieldPresent=$false;effectiveStoreFile=$false;
        accountReadCount=0;authenticatedObservation=$false;continuityStatus='NOT_RUN';
        strongPrincipalProven=$false;workspaceContinuityProven=$false;sentMethods=@();receivedFrameCount=0;notificationCount=0
    }
    $methods=[Collections.Generic.List[string]]::new()
    $state=@{MessageCount=0;TotalBytes=0;NotificationCount=0;BaselineSeen=$false;Diagnostic=$null}
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try {
        if ($TimeoutMs -le 0 -or $TimeoutMs -gt 60000) { Stop-K32 'invalid_inputs' }
        $canonicalExpectedHome=Get-K32Path $ExpectedHome
        $cwd=Get-K32Path $Workspace
        $receipt.failedStage='initialize'
        Send-K32Frame -Child $Child -Method 'initialize' -Params @{clientInfo=@{name='codex_timezone';title='K3.2 read-only preflight';version='k3.2'};capabilities=$null} -Id 1 -RemainingMs ($TimeoutMs-[int]$timer.ElapsedMilliseconds) -ExpectedWorkspace $cwd
        $methods.Add('initialize')
        $init=Read-K32Result $Child $state 1 $timer $TimeoutMs -Method 'initialize'
        $receipt.initializeSucceeded=$true
        try { $actualHome=Get-K32Path $init.codexHome } catch { Stop-K32 'home_mismatch' }
        if (![string]::Equals($canonicalExpectedHome,$actualHome,[StringComparison]::OrdinalIgnoreCase)) { Stop-K32 'home_mismatch' }
        $receipt.homeMatched=$true
        Send-K32Frame -Child $Child -Method 'initialized' -Params @{} -Id $null -RemainingMs ($TimeoutMs-[int]$timer.ElapsedMilliseconds) -ExpectedWorkspace $cwd
        $methods.Add('initialized')
        $receipt.failedStage='requirements'
        Send-K32Frame -Child $Child -Method 'configRequirements/read' -Params $null -Id 2 -RemainingMs ($TimeoutMs-[int]$timer.ElapsedMilliseconds) -ExpectedWorkspace $cwd
        $methods.Add('configRequirements/read')
        $policy=Read-K32Result $Child $state 2 $timer $TimeoutMs -Method 'configRequirements/read'
        $receipt.requirementsReadSucceeded=$true
        if (Has-K32Key $policy 'requirements') {
            $requirements=$policy.requirements
            if ($null -ne $requirements) {
                if (Has-K32Key $requirements 'cliAuthCredentialsStore') {
                    $receipt.requirementStorePresent=$true
                    if ($null -ne $requirements.cliAuthCredentialsStore) {
                        if ($requirements.cliAuthCredentialsStore -isnot [string] -or $requirements.cliAuthCredentialsStore -cne 'file') { Stop-K32 'requirement_not_file' }
                        $receipt.requirementStoreFile=$true
                    }
                }
            }
        }
        $receipt.failedStage='config'
        Send-K32Frame -Child $Child -Method 'config/read' -Params @{includeLayers=$false;cwd=$cwd} -Id 3 -RemainingMs ($TimeoutMs-[int]$timer.ElapsedMilliseconds) -ExpectedWorkspace $cwd
        $methods.Add('config/read')
        $config=Read-K32Result $Child $state 3 $timer $TimeoutMs -Method 'config/read'
        $receipt.configReadSucceeded=$true
        if (!(Has-K32Key $config.config 'cli_auth_credentials_store')) { Stop-K32 'effective_store_unavailable' }
        $receipt.effectiveStoreFieldPresent=$true
        if ($config.config.cli_auth_credentials_store -isnot [string] -or $config.config.cli_auth_credentials_store -cne 'file') { Stop-K32 'effective_store_not_file' }
        $receipt.effectiveStoreFile=$true
        $config=$null; $policy=$null; $init=$null
        $receipt.failedStage='account_first'
        Send-K32Frame -Child $Child -Method 'account/read' -Params @{refreshToken=$false} -Id 4 -RemainingMs ($TimeoutMs-[int]$timer.ElapsedMilliseconds) -ExpectedWorkspace $cwd
        $methods.Add('account/read')
        $firstResult=Read-K32Result $Child $state 4 $timer $TimeoutMs -Method 'account/read'
        # Fresh empty-home probes must reject any identity before a second read,
        # including unsupported providers; no implicit shared/default account use.
        if ($ExpectUnauthenticated -and (Has-K32Key $firstResult 'account') -and $null -ne $firstResult.account) {
            $receipt.accountReadCount++
            Stop-K32 'unexpected_authenticated_source'
        }
        $first=Get-K32Account $firstResult
        $firstResult=$null
        $receipt.accountReadCount++; $state.BaselineSeen=$true
        $receipt.failedStage='account_second'
        Send-K32Frame -Child $Child -Method 'account/read' -Params @{refreshToken=$false} -Id 5 -RemainingMs ($TimeoutMs-[int]$timer.ElapsedMilliseconds) -ExpectedWorkspace $cwd
        $methods.Add('account/read')
        $second=Get-K32Account (Read-K32Result $Child $state 5 $timer $TimeoutMs -Method 'account/read')
        $receipt.accountReadCount++
        $receipt.failedStage='final_drain'
        # A quiet read catches already queued duplicate/late frames. The owner must
        # stop its child immediately afterward; this is not a future-event guarantee.
        Read-K32Result -Child $Child -State $state -Id 0 -Timer $timer -Budget $TimeoutMs -Quiet $true | Out-Null
        if ($null -eq $first -and $null -eq $second) {
            $receipt.status='auth_required';$receipt.reasonCode='auth_required';$receipt.continuityStatus='NOT_RUN'
        } elseif ($null -eq $first -or $null -eq $second) { Stop-K32 'identity_observation_changed' }
        else {
            foreach($key in @('type','email','planType')) {
                if ($null -eq $first[$key] -and $null -eq $second[$key]) { continue }
                if ($null -eq $first[$key] -or $null -eq $second[$key] -or ![string]::Equals($first[$key],$second[$key],[StringComparison]::Ordinal)) { Stop-K32 'identity_observation_changed' }
            }
            $receipt.status='observed_identity_stable';$receipt.authenticatedObservation=$true;$receipt.continuityStatus='observed_identity_stable'
        }
        $receipt.failedStage=$null
    } catch {
        $allowed=@('invalid_inputs','home_mismatch','malformed_initialize','outbound_rejected','write_failed','read_failed','frame_too_large','malformed_response','message_budget_exceeded','timeout','unexpected_server_request','unexpected_notification','unexpected_response_id','rpc_error','identity_observation_changed','unexpected_authenticated_source','malformed_account','unsupported_account_type','malformed_requirements','requirement_not_file','malformed_config','effective_store_unavailable','effective_store_not_file')
        $code=$_.Exception.Message
        if ($code -cnotin $allowed) { $code='incomplete' }
        $receipt.status='failed';$receipt.reasonCode=$code;$receipt.continuityStatus='NOT_RUN';$receipt.authenticatedObservation=$false
        $receipt.diagnostic=$state.Diagnostic
    } finally {
        $first=$null;$firstResult=$null;$second=$null;$config=$null;$policy=$null;$init=$null;$requirements=$null
        $receipt.sentMethods=$methods.ToArray();$receipt.receivedFrameCount=$state.MessageCount;$receipt.notificationCount=$state.NotificationCount
        $timer.Stop()
    }
    [pscustomobject]$receipt
}
Export-ModuleMember -Function Invoke-K32ReadonlyHandshake
