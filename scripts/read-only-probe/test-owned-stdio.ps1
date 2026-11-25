[CmdletBinding()]
param([string]$Rustc = 'rustc')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$evidence = Join-Path $root ('environment/k3-2-readonly-validation-20261025-a/transport-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $evidence | Out-Null
function Assert($condition, [string]$name) { if (!$condition) { throw "ASSERT: $name" }; "PASS $name" }
function Expect-Code([scriptblock]$action, [string]$code) {
    try { & $action; throw "Expected $code" } catch {
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        Assert ($ex -is [K32Probe.ProbeException] -and $ex.ReasonCode -eq $code) $code
    }
}
Start-Transcript -Path (Join-Path $evidence 'test.log') | Out-Null
try {
    # Removing the transport must fail this first behavioral availability gate.
    Assert (Test-Path (Join-Path $PSScriptRoot 'OwnedStdioChild.cs')) 'owned transport available'
    Add-Type -Path (Join-Path $PSScriptRoot 'OwnedStdioChild.cs')
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class CanaryHandle {
 [StructLayout(LayoutKind.Sequential)] public struct SA { public int size; public IntPtr sd; public int inherit; }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr CreateEvent(ref SA sa,bool manual,bool initial,string name);
 [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
 public static IntPtr Make() { var sa=new SA {size=Marshal.SizeOf(typeof(SA)),inherit=1}; return CreateEvent(ref sa,false,false,null); }
}
'@
    $exe = Join-Path $evidence 'owned fixture.exe'
    $oldTmp=$env:TMP; $oldTemp=$env:TEMP
    try {
        $env:TMP=$evidence; $env:TEMP=$evidence
        & $Rustc --edition 2021 (Join-Path $PSScriptRoot 'fixture.rs') -o $exe
        if ($LASTEXITCODE -ne 0) { throw 'fixture_compile_failed' }
    } finally { $env:TMP=$oldTmp; $env:TEMP=$oldTemp }
    $childEnv = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $childEnv.Add('SystemRoot', $env:SystemRoot)
    $childEnv.Add('K32_VALUE', 'explicit-only')
    $original = [Environment]::GetEnvironmentVariable('K32_PARENT_CANARY')
    [Environment]::SetEnvironmentVariable('K32_PARENT_CANARY', 'parent-only')
    $canary = [CanaryHandle]::Make()
    $children = [System.Collections.Generic.List[K32Probe.OwnedStdioChild]]::new()
    function Spawn([string[]]$arguments) { $c=[K32Probe.OwnedStdioChild]::Start($exe,$arguments,$evidence,$childEnv); $children.Add($c); return $c }
    function Reap($c) { $r=$c.Stop($c.Identity,5000); Assert ($r.Confirmed -and $r.ProcessReaped -and $r.JobEmpty -and $r.ReaderJoined -and $r.WriterJoined) 'cleanup receipt fully confirmed' }
    try {
        # Test-only fault injection: delay the real writer beyond failed-start join budget,
        # then throw before ResumeThread. The production API contains no injection hook.
        $injected=(Get-Content -Raw (Join-Path $PSScriptRoot 'OwnedStdioChild.cs')).Replace('namespace K32Probe','namespace K32Regression')
        $injected=$injected.Replace('new Thread(c.WriteWorker)', 'new Thread(() => StartupFailureHooks.RunWriter(c, c.WriteWorker))')
        $injected=$injected.Replace('c.reader.Start(); c.writer.Start();', 'c.reader.Start(); c.writer.Start(); StartupFailureHooks.Fail(c);')
        $injected+=@'

namespace K32Regression {
 public static class StartupFailureHooks {
  public static readonly System.Threading.ManualResetEvent Entered = new System.Threading.ManualResetEvent(false);
  public static readonly System.Threading.ManualResetEvent Release = new System.Threading.ManualResetEvent(false);
  public static OwnedStdioChild Captured;
  public static System.Exception WorkerError;
  public static void RunWriter(OwnedStdioChild child, System.Threading.ThreadStart run) {
   Entered.Set();
   try { if(!Release.WaitOne(15000)) throw new System.TimeoutException(); run(); }
   catch(System.Exception e) { WorkerError=e; }
  }
  public static void Fail(OwnedStdioChild child) {
   Captured=child;
   if(!Entered.WaitOne(2000)) throw new System.Exception("writer_not_entered");
   throw new ProbeException("synthetic_start_failure");
  }
 }
}
'@
        Add-Type -TypeDefinition $injected
        $startupReason=$null
        try { [K32Regression.OwnedStdioChild]::Start($exe,@('sleep'),$evidence,$childEnv) | Out-Null }
        catch { $errorObject=$_.Exception; while($errorObject.InnerException) {$errorObject=$errorObject.InnerException}; $startupReason=$errorObject.ReasonCode }
        $captured=[K32Regression.StartupFailureHooks]::Captured
        $binding=[Reflection.BindingFlags]'Instance,NonPublic'
        $wake=$captured.GetType().GetField('writerWake',$binding).GetValue($captured)
        $delayedWriter=$captured.GetType().GetField('writer',$binding).GetValue($captured)
        try {
            Assert ($startupReason -ceq 'start_cleanup_unconfirmed') 'startup delayed writer remains unconfirmed'
            Assert ($delayedWriter.IsAlive -and !$wake.SafeWaitHandle.IsClosed) 'startup failure preserves live writer event'
            foreach($field in @('job','process','stdinWrite','stdoutRead')) {
                Assert ($captured.GetType().GetField($field,$binding).GetValue($captured) -ne [IntPtr]::Zero) "startup retains owned $field"
            }
        } finally {
            [K32Regression.StartupFailureHooks]::Release.Set() | Out-Null
            $joined=$delayedWriter.Join(3000)
            # The RED version already invalidated the handles. Do not hide its failure
            # behind a second Dispose exception; the fixed implementation can retry Stop.
            if (!$wake.SafeWaitHandle.IsClosed) { $retry=$captured.Stop($captured.Identity,5000) }
        }
        Assert ($joined -and $null -eq [K32Regression.StartupFailureHooks]::WorkerError) 'delayed writer exits without disposed-event exception'
        Assert $retry.Confirmed 'startup cleanup retry confirms real completion'
        # Catches inherited environment/cwd, excess handles, quoting and late Job assignment.
        $quoted = 'space "quote" trailing\'
        $c=Spawn @('inspect',$canary.ToInt64().ToString(),$quoted)
        Assert ($c.CreatedSuspended -and $c.JobAssignedBeforeResume -and $c.InheritedHandleCount -eq 3) 'atomic startup diagnostics'
        Assert ($c.ReadLine(3000) -ceq "explicit-only|true|$evidence|1|0|$quoted") 'actual environment cwd job handles argv'
        Assert ($env:K32_PARENT_CANARY -ceq 'parent-only') 'parent environment unchanged'
        Reap $c
        $c=Spawn @('echo'); $foreign=Spawn @('echo')
        $environmentBefore=[Environment]::GetEnvironmentVariables()
        Expect-Code { $c.Stop($foreign.Identity,1000) } 'identity_mismatch'
        $c.WriteLine('hello 中文',1000); Assert ($c.ReadLine(1000) -ceq 'hello 中文') 'bidirectional UTF8'
        $foreign.WriteLine('unrelated alive',1000); Assert ($foreign.ReadLine(1000) -ceq 'unrelated alive') 'foreign child survives rejection'
        Expect-Code { $c.ReadLine(80) } 'read_timeout'
        Expect-Code { $c.WriteLine("two`nframes",100) } 'invalid_write_frame'
        $boundary='b' * 1048576
        $c.WriteLine($boundary,3000); Assert ($c.ReadLine(3000) -ceq $boundary) 'exact 1MiB frame accepted'
        $environmentAfter=[Environment]::GetEnvironmentVariables()
        Assert ($environmentBefore.Count -eq $environmentAfter.Count -and @($environmentBefore.Keys | Where-Object { $environmentBefore[$_] -cne $environmentAfter[$_] }).Count -eq 0) 'all parent environment entries unchanged'
        Reap $c; Reap $foreign
        Reap $c
        $c=Spawn @('sleep'); $timer=[Diagnostics.Stopwatch]::StartNew()
        Expect-Code { $c.WriteLine(('x' * 1048575),100) } 'write_timeout'
        Assert ($timer.ElapsedMilliseconds -lt 2000) 'blocked write deadline bounded'
        Expect-Code { $c.WriteLine('again',100) } 'write_poisoned'
        Reap $c
        foreach ($case in @(@('oversize','frame_too_large'),@('invalid','invalid_utf8'),@('crash','child_eof'),@('flood','read_queue_overflow'))) {
            $c=Spawn @($case[0]); Start-Sleep -Milliseconds 250
            Expect-Code { $c.ReadLine(2000) } $case[1]
            if ($case[0] -eq 'crash') {
                Expect-Code { $c.WriteLine('after crash',1000) } 'write_failed'
                Expect-Code { $c.WriteLine('again',100) } 'write_poisoned'
            }
            Reap $c
        }
        $c=Spawn @('descendant'); $descendantPid=[int]$c.ReadLine(3000)
        $descendant=[Diagnostics.Process]::GetProcessById($descendantPid)
        try { Reap $c; Assert $descendant.WaitForExit(1000) 'descendant reaped despite inherited pipe' } finally { $descendant.Dispose() }
        Expect-Code { [K32Probe.OwnedStdioChild]::Start((Join-Path $evidence 'missing.exe'),@(),$evidence,$childEnv) } 'start_failed'
        'ALL TRANSPORT TESTS PASSED'
    } finally {
        foreach ($c in $children) { $c.Dispose() }
        [CanaryHandle]::CloseHandle($canary) | Out-Null
        [Environment]::SetEnvironmentVariable('K32_PARENT_CANARY',$original)
    }
} finally { Stop-Transcript | Out-Null; Write-Output "Evidence: $evidence" }
