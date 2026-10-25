[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'ReadOnlyProtocol.psm1'
$script:checks = 0
function Assert($condition, [string]$label) {
    if (!$condition) { throw "ASSERT: $label" }
    $script:checks++
}
if (Test-Path -LiteralPath $modulePath) { Import-Module $modulePath -Force }
else { function Invoke-K32ReadonlyHandshake { [pscustomobject]@{ status='not_implemented' } } }

$expectedHome = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$workspace = $PSScriptRoot
$canary = 'SECRET_CANARY_PERSONAL_TOKEN_9e81'
function Frame($id, $result) { @{id=$id;result=$result} | ConvertTo-Json -Depth 15 -Compress }
function Account([object]$email='synthetic@example.invalid', [string]$plan='plus') {
    @{type='chatgpt';email=$email;planType=$plan}
}
function Good-Frames($one=(Account), $two=(Account)) {
    @(
        (Frame 1 @{codexHome=$expectedHome;platformFamily='windows';platformOs='windows';userAgent=$canary}),
        (Frame 2 @{requirements=$null}),
        (Frame 3 @{config=@{cli_auth_credentials_store='file';secret=$canary};origins=@{}}),
        (Frame 4 @{account=$one;requiresOpenaiAuth=$true}),
        (Frame 5 @{account=$two;requiresOpenaiAuth=$true})
    )
}
function Fake-Child([object[]]$frames) {
    $queue = [Collections.Generic.Queue[object]]::new()
    foreach ($frame in $frames) { $queue.Enqueue($frame) }
    $child = [pscustomobject]@{Identity=[pscustomobject]@{Pid=123};Frames=$queue;Writes=[Collections.Generic.List[string]]::new();Timeouts=[Collections.Generic.List[int]]::new()}
    $child | Add-Member ScriptMethod WriteLine {
        param([string]$line,[int]$timeoutMs)
        $this.Timeouts.Add($timeoutMs)
        $this.Writes.Add($line)
    }
    $child | Add-Member ScriptMethod ReadLine {
        param([int]$timeoutMs)
        $this.Timeouts.Add($timeoutMs)
        if ($this.Frames.Count -eq 0) {
            $ex=[InvalidOperationException]::new('read_timeout'); $ex.Data['ReasonCode']='read_timeout'; throw $ex
        }
        $next=$this.Frames.Dequeue()
        if ($next -is [Exception]) { throw $next }
        return $next
    }
    $child
}
function Probe($child) { Invoke-K32ReadonlyHandshake -Child $child -ExpectedHome $expectedHome -Workspace $workspace -TimeoutMs 1500 }
function Methods($child) { @($child.Writes | ForEach-Object { ($_ | ConvertFrom-Json).method }) }
function No-Accounts($child,[string]$label) { Assert (@((Methods $child) | Where-Object {$_ -ceq 'account/read'}).Count -eq 0) $label }
function Safe($result,[string]$label) {
    $json=$result | ConvertTo-Json -Depth 10 -Compress
    Assert (!$json.Contains($canary)) "$label excludes secret canary"
    Assert (!$json.Contains('synthetic@example.invalid')) "$label excludes identity"
    Assert ($result.strongPrincipalProven -eq $false) "$label never claims principal"
    Assert ($result.workspaceContinuityProven -eq $false) "$label never claims workspace"
}

# Removing any successful protocol gate or admitting another wire method breaks this contract.
$child=Fake-Child (Good-Frames)
$result=Probe $child
Assert ($result.status -ceq 'observed_identity_stable') 'valid handshake completes with stable exposed observation'
Assert ($result.homeMatched -and $result.effectiveStoreFile -and $result.configReadSucceeded) 'success requires real gates'
Assert ($result.accountReadCount -eq 2) 'two real account responses observed'
Assert (((Methods $child) -join ',') -ceq 'initialize,initialized,configRequirements/read,config/read,account/read,account/read') 'wire method allowlist and order'
Assert (($result.sentMethods -join ',') -ceq ((Methods $child) -join ',')) 'safe methods receipt follows actual writes'
Assert (($child.Timeouts | Measure-Object -Minimum).Minimum -gt 0) 'all transport deadlines positive'
$wire=@($child.Writes | ForEach-Object { $_|ConvertFrom-Json })
Assert ($wire[2].params -eq $null) 'requirements params use pinned null form'
Assert ($wire[3].params.cwd -ceq $workspace -and !$wire[3].params.includeLayers) 'effective config uses process workspace'
Assert (!$wire[4].params.refreshToken -and !$wire[5].params.refreshToken) 'account reads explicitly avoid proactive refresh'
Safe $result 'stable result'
Assert ($null -eq $result.diagnostic) 'documented nested requirements null has no rejecting diagnostic'

# The pinned official server includes optional emittedAtMs envelope metadata.
# It is timing metadata, not an account/config field and is never exported.
foreach($timestamp in @($null,[long]1780000000000)) {
    $frames=Good-Frames
    $notice=@{method='configWarning';params=@{secret=$canary};emittedAtMs=$timestamp}|ConvertTo-Json -Compress
    $frames=@($frames[0],$notice)+@($frames[1..4])
    $child=Fake-Child $frames; $result=Probe $child
    Assert ($result.status -ceq 'observed_identity_stable') 'official optional notification timestamp accepted'
    Assert ($result.notificationCount -eq 1 -and $result.accountReadCount -eq 2) 'timestamp notification does not consume pending response'
    Safe $result 'timestamp notification'
}
foreach($timestamp in @($true,'1780000000000',1.5,@{},@())) {
    $frames=Good-Frames
    $notice=@{method='configWarning';params=@{};emittedAtMs=$timestamp}|ConvertTo-Json -Compress -Depth 5
    $frames=@($frames[0],$notice)+@($frames[1..4])
    $child=Fake-Child $frames; $result=Probe $child
    Assert ($result.status -ceq 'failed' -and $result.diagnostic.boundary -ceq 'notification_envelope') 'invalid notification timestamp rejected'
    No-Accounts $child 'malformed notification stops before account reads'
    Safe $result 'malformed timestamp'
}
$frames=Good-Frames
$notice=@{method='configWarning';params=@{};emittedAtMs=[long]1780000000000;$canary=$canary}|ConvertTo-Json -Compress
$frames=@($frames[0],$notice)+@($frames[1..4])
$child=Fake-Child $frames; $result=Probe $child
Assert ($result.status -ceq 'failed') 'timestamp compatibility does not admit arbitrary envelope fields'
No-Accounts $child 'unknown notification field stops before accounts'; Safe $result 'unknown envelope field'
$frames=Good-Frames
$frames=@($frames[0],'{"method":"remoteControl/status/changed","params":{"secret":"SECRET_CANARY_PERSONAL_TOKEN_9e81"},"emittedAtMs":1780000000000}')+@($frames[1..4])
$child=Fake-Child $frames; $result=Probe $child
Assert ($result.status -ceq 'observed_identity_stable' -and $result.notificationCount -eq 1) 'unsolicited official remote-control status is discarded without changing handshake'
Assert ((Methods $child) -cnotcontains 'remoteControl/status/read') 'status notification never enables or queries remote control'
Safe $result 'known startup notification'
$frames=Good-Frames
$frames=@($frames[0],'{"method":"mcpServer/startupStatus/updated","params":{"secret":"SECRET_CANARY_PERSONAL_TOKEN_9e81"},"emittedAtMs":1780000000000}')+@($frames[1..4])
$child=Fake-Child $frames; $result=Probe $child
Assert ($result.reasonCode -ceq 'unexpected_notification' -and $result.diagnostic.shape.knownNotificationMethod -ceq 'mcpServer/startupStatus/updated') 'other known notifications remain diagnostic only'
No-Accounts $child 'other notification stops before accounts'; Safe $result 'unaccepted known method'

# Removing the boundary projection would merge these distinct failures again.
# Unknown key names and values deliberately carry the same privacy canary.
$diagnosticCases=@(
    @{frame='{';boundary='json_decode';resultKind='unavailable';requirementsKind='unavailable'},
    @{frame='null';boundary='top_level';resultKind='missing';requirementsKind='missing'},
    @{frame='{"id":2,"result":null}';boundary='method_result';resultKind='null';requirementsKind='missing'},
    @{frame='{"id":2,"result":false}';boundary='method_result';resultKind='boolean';requirementsKind='missing'},
    @{frame='{"id":2,"result":"SECRET_CANARY_PERSONAL_TOKEN_9e81"}';boundary='method_result';resultKind='string';requirementsKind='missing'},
    @{frame='{"id":2,"result":[],"SECRET_CANARY_PERSONAL_TOKEN_9e81":"SECRET_CANARY_PERSONAL_TOKEN_9e81"}';boundary='success_envelope';resultKind='array';requirementsKind='missing'},
    @{frame='{"id":2,"result":{"requirements":null},"SECRET_CANARY_PERSONAL_TOKEN_9e81":"SECRET_CANARY_PERSONAL_TOKEN_9e81"}';boundary='success_envelope';resultKind='object';requirementsKind='null'},
    @{frame='{"id":2,"result":{"requirements":false,"SECRET_CANARY_PERSONAL_TOKEN_9e81":"SECRET_CANARY_PERSONAL_TOKEN_9e81"}}';boundary='method_result';resultKind='object';requirementsKind='boolean'},
    @{frame='{"id":2,"result":{"requirements":null,"Requirements":"SECRET_CANARY_PERSONAL_TOKEN_9e81"}}';boundary='json_decode';resultKind='unavailable';requirementsKind='unavailable'}
)
foreach($case in $diagnosticCases){
    $frames=Good-Frames; $frames[1]=$case.frame
    $child=Fake-Child $frames; $result=Probe $child
    Assert ($result.status -ceq 'failed') 'unsupported diagnostic fixture remains rejected'
    Assert ($result.diagnostic.boundary -ceq $case.boundary) 'failure reports its actual rejecting boundary'
    Assert ($result.diagnostic.shape.resultKind -ceq $case.resultKind) 'result kind distinguishes missing/null/scalar/object'
    Assert ($result.diagnostic.shape.requirementsKind -ceq $case.requirementsKind) 'nested requirements kind is independent from outer result'
    No-Accounts $child 'diagnostic rejection happens before account reads'
    Safe $result 'fixed projection diagnostic'
}

# A supposedly fresh home must never silently adopt a shared/default identity.
# Removing the switch guard makes this emit a second account request and report stable.
foreach ($unexpectedIdentity in @((Account),@{type='apiKey'},@{type='chatgpt';email=$canary;planType='pro'},@{type='unknownProvider';private=$canary})) {
    $child=Fake-Child (Good-Frames -one $unexpectedIdentity -two $unexpectedIdentity)
    $result=Invoke-K32ReadonlyHandshake -Child $child -ExpectedHome $expectedHome -Workspace $workspace -TimeoutMs 1500 -ExpectUnauthenticated
    Assert ($result.status -ceq 'failed' -and $result.reasonCode -ceq 'unexpected_authenticated_source') 'fresh home rejects any nonnull first identity'
    Assert ($result.failedStage -ceq 'account_first' -and $result.accountReadCount -eq 1) 'fresh home stops on first observed account'
    Assert (@((Methods $child) | Where-Object {$_ -ceq 'account/read'}).Count -eq 1) 'fresh home failure never sends second account request'
    Safe $result 'unexpected fresh-home identity'
}
$child=Fake-Child (Good-Frames -one $null -two $null)
$result=Invoke-K32ReadonlyHandshake -Child $child -ExpectedHome $expectedHome -Workspace $workspace -TimeoutMs 1500 -ExpectUnauthenticated
Assert ($result.status -ceq 'auth_required' -and $result.accountReadCount -eq 2) 'fresh home actual null still checks twice and requires auth'
Assert (@((Methods $child) | Where-Object {$_ -ceq 'account/read'}).Count -eq 2) 'fresh-home null path emits two account reads'
Safe $result 'fresh-home actual null'

foreach ($candidateHome in @($null,'C:\other-owned-home',($expectedHome + '-prefix'))) {
    $frames=Good-Frames; $frames[0]=Frame 1 @{codexHome=$candidateHome;platformFamily='windows';platformOs='windows';userAgent=$canary}
    $child=Fake-Child $frames; $result=Probe $child
    Assert ($result.status -ceq 'failed' -and $result.failedStage -ceq 'initialize') 'missing/mismatched home fails initialize'
    Assert ($child.Writes.Count -eq 1) 'home failure stops before initialized'
    No-Accounts $child 'home failure never reads account'; Safe $result 'home failure'
}
foreach ($config in @(@{},@{cli_auth_credentials_store=$null},@{cli_auth_credentials_store='keyring'},@{cli_auth_credentials_store='auto'},@{cli_auth_credentials_store='ephemeral'},@{cli_auth_credentials_store='FILE'},@{cli_auth_credentials_store=@('file')})) {
    $frames=Good-Frames; $frames[2]=Frame 3 @{config=$config;origins=@{cli_auth_credentials_store=@{name=@{type='sessionFlags'};version='file'}};layers=@(@{config=@{cli_auth_credentials_store='file'}})}
    $child=Fake-Child $frames; $result=Probe $child
    Assert ($result.status -ceq 'failed' -and $result.failedStage -ceq 'config') 'missing/non-file store never inferred from layers'
    No-Accounts $child 'config failure never reads account'; Safe $result 'config failure'
}
foreach ($store in @('keyring','auto','ephemeral','FILE',@('file'))) {
    $frames=Good-Frames; $frames[1]=Frame 2 @{requirements=@{cliAuthCredentialsStore=$store;secret=$canary}}
    $child=Fake-Child $frames; $result=Probe $child
    Assert ($result.status -ceq 'failed' -and $result.failedStage -ceq 'requirements') 'contradictory policy stops'
    Assert ($child.Writes.Count -eq 3) 'policy failure stops before config/account'
    No-Accounts $child 'policy failure never reads account'; Safe $result 'policy failure'
}
foreach ($requirements in @(@{},@{cliAuthCredentialsStore=$null},@{cliAuthCredentialsStore='file'})) {
    $frames=Good-Frames; $frames[1]=Frame 2 @{requirements=$requirements}
    $result=Probe (Fake-Child $frames)
    Assert ($result.status -ceq 'observed_identity_stable') 'unconstrained/file requirement still requires independent effective file config'
}

foreach ($pair in @(@($null,$null),@($null,(Account)),@((Account),$null),@((Account),(Account 'changed@example.invalid')), @((Account),(Account 'synthetic@example.invalid' 'pro')))) {
    $child=Fake-Child (Good-Frames -one $pair[0] -two $pair[1]); $result=Probe $child
    if ($null -eq $pair[0] -and $null -eq $pair[1]) {
        Assert ($result.status -ceq 'auth_required' -and $result.reasonCode -ceq 'auth_required') 'only all actual-null reads classify auth_required'
    } else { Assert ($result.reasonCode -ceq 'identity_observation_changed') 'mixed or changed observations never stable' }
    Assert ($result.accountReadCount -eq 2) 'null first observation still checks second read'
    Safe $result 'identity classification'
}
$result=Probe (Fake-Child (Good-Frames -one (Account $null) -two (Account $null)))
Assert ($result.status -ceq 'observed_identity_stable') 'nullable email equality stays weak observation only'; Safe $result 'nullable identity'

$badEnvelopes=@(
    '{', 'null', '[]', '{"id":1,"id":1,"result":{}}', '{"id":1,"result":{},"Result":{}}',
    (Frame 99 @{}), '{"id":1.0,"result":{}}', '{"id":"1","result":{}}',
    '{"id":1,"result":{},"error":{"message":"SECRET_CANARY_PERSONAL_TOKEN_9e81"}}',
    '{"id":1,"method":"account/chatgptAuthTokens/refresh","params":{"token":"SECRET_CANARY_PERSONAL_TOKEN_9e81"}}',
    ('x' * 1048577), ''
)
foreach ($bad in $badEnvelopes) {
    $frames=Good-Frames; $frames[0]=$bad
    $child=Fake-Child $frames; $result=Probe $child
    Assert ($result.status -ceq 'failed') 'malformed/oversize/request/unrelated envelope fails closed'
    No-Accounts $child 'bad envelope never reads account'; Safe $result 'bad envelope'
}
foreach ($method in @('turn/start','account/login/start','config/value/write','config/batchWrite')) {
    $frames=Good-Frames; $frames[1]=(@{id=2;method=$method;params=@{private=$canary}} | ConvertTo-Json -Compress)
    $child=Fake-Child $frames; $result=Probe $child
    Assert ($result.reasonCode -ceq 'unexpected_server_request') 'forbidden server requests stop rather than reply'
    Assert (!((Methods $child) -ccontains $method)) 'forbidden method never emitted'; Safe $result 'forbidden server request'
}
foreach ($index in @(1,2,3,4)) {
    $frames=Good-Frames; $frames[$index]=Frame 1 @{}
    $result=Probe (Fake-Child $frames)
    Assert ($result.reasonCode -ceq 'unexpected_response_id') 'duplicate/late response cannot satisfy later phase'; Safe $result 'duplicate response'
}
$frames=Good-Frames; $frames+=Frame 5 @{account=(Account);requiresOpenaiAuth=$true}
$result=Probe (Fake-Child $frames)
Assert ($result.reasonCode -ceq 'unexpected_response_id') 'queued duplicate after final read rejected'
$frames=Good-Frames
$frames=@($frames[0..3])+@('{"method":"account/updated","params":{"private":"SECRET_CANARY_PERSONAL_TOKEN_9e81"}}')+@($frames[4])
$result=Probe (Fake-Child $frames)
Assert ($result.reasonCode -ceq 'identity_observation_changed') 'account update after baseline invalidates observation'; Safe $result 'update notification'

foreach ($resultValue in @(@{requiresOpenaiAuth=$true},@{account=(Account);requiresOpenaiAuth='true'},@{account=@{type='chatgpt';email='x'};requiresOpenaiAuth=$true},@{account=@{type='apiKey'};requiresOpenaiAuth=$true})) {
    $frames=Good-Frames; $frames[3]=Frame 4 $resultValue
    $result=Probe (Fake-Child $frames)
    Assert ($result.status -ceq 'failed' -and $result.reasonCode -cne 'auth_required') 'malformed/missing/unsupported account is not null authentication'; Safe $result 'malformed account'
}
$frames=Good-Frames; $frames[4]='{"id":5,"error":{"code":401,"message":"SECRET_CANARY_PERSONAL_TOKEN_9e81"}}'
$result=Probe (Fake-Child $frames)
Assert ($result.status -ceq 'failed' -and $result.reasonCode -ceq 'rpc_error') 'RPC errors never classify complete/auth_required'; Safe $result 'server error'
$ex=[InvalidOperationException]::new($canary); $frames=Good-Frames; $frames[3]=$ex
$result=Probe (Fake-Child $frames)
Assert ($result.reasonCode -ceq 'read_failed' -and $result.accountReadCount -eq 0) 'transport exception sanitized'; Safe $result 'transport failure'
$frames=@(); for($i=0;$i -lt 65;$i++){ $frames+='{"method":"configWarning","params":{"secret":"SECRET_CANARY_PERSONAL_TOKEN_9e81"}}' }
$result=Probe (Fake-Child $frames)
Assert ($result.status -ceq 'failed' -and $result.reasonCode -ceq 'message_budget_exceeded') 'notification flood bounded'; Safe $result 'flood'

# Explicit outbound validator rejects before any transport write, including malformed allowed params.
$module=Get-Module ReadOnlyProtocol
foreach ($item in @(@('turn/start',@{}),@('account/login/start',@{}),@('config/value/write',@{}),@('account/read',@{refreshToken=$true}),@('config/read',@{includeLayers=$true;cwd=$workspace}),@('account/read',@{refreshToken=$false;extra=$canary}))) {
    $child=Fake-Child @()
    $blocked=& $module { param($c,$m,$p,$w) try { Send-K32Frame -Child $c -Method $m -Params $p -Id 1 -RemainingMs 100 -ExpectedWorkspace $w; $false } catch { $true } } $child $item[0] $item[1] $workspace
    Assert $blocked 'outbound allowlist rejects forbidden method/params'
    Assert ($child.Writes.Count -eq 0) 'outbound rejection happens before WriteLine'
}
"PASS readonly protocol: $script:checks assertions; synthetic transport only; no CLI/services/auth/model calls"
