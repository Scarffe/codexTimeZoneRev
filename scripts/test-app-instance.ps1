$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'build-desktop-prototype.ps1') *> (Join-Path $root 'environment/stage-g-evidence/native-build.log')
$output=Join-Path $root "environment\stage-g-instance-$([guid]::NewGuid().ToString('N'))"
$a=Join-Path $output 'a';$b=Join-Path $output 'b'
New-Item -ItemType Directory $a,$b | Out-Null
$fixture=Join-Path $root 'environment/desktop-prototype/Release/instance_fixture.exe'
Copy-Item $fixture (Join-Path $a 'codex_timezone.exe');Copy-Item $fixture (Join-Path $b 'codex_timezone.exe')
$owned=[Collections.Generic.List[object]]::new();$checks=[Collections.Generic.List[string]]::new()
function Launch([string]$directory,[string]$scope,[string[]]$extra=@()) {
 $id=[guid]::NewGuid().ToString('N');$result=Join-Path $output "$id.json";$quit="Local\CodexTimeZone.FixtureQuit.$id"
 $args=@("--scope=$scope","--output=$result","--quit=$quit")+$extra
 $process=Start-Process (Join-Path $directory 'codex_timezone.exe') -ArgumentList $args -WindowStyle Hidden -PassThru
 $item=[pscustomobject]@{process=$process;result=$result;quit=$quit;directory=$directory};$owned.Add($item);return $item
}
function ReadResult($item,[bool]$window=$false) {
 $path=$item.result+$(if($window){'.state'}else{''});$deadline=(Get-Date).AddSeconds(17)
 do { if(Test-Path $path) {try {return Get-Content $path -Raw | ConvertFrom-Json} catch {}};Start-Sleep -Milliseconds 50 } while((Get-Date)-lt $deadline)
 throw "Fixture result timeout: $path"
}
function Check([bool]$condition,[string]$label) {if(!$condition){throw $label};$checks.Add($label)}
function StopOwned($item) {
 if(!$item.process.HasExited) {
  try {$event=[Threading.EventWaitHandle]::OpenExisting($item.quit);try{$event.Set()|Out-Null}finally{$event.Dispose()}} catch {}
  if(!$item.process.WaitForExit(21000)){throw 'Owned fixture failed to exit within its bounded lifetime'}
 }
}
try {
 $scope=[guid]::NewGuid().ToString('N');$first=Launch $a $scope;$r=ReadResult $first;$state=ReadResult $first $true
 Check ($r.decision -eq 'start' -and !$state.visible) 'First instance starts hidden'
 $second=Launch $b $scope;$r=ReadResult $second
 Check ($r.decision -eq 'reused' -and $r.target -eq $first.process.Id) 'Cross-directory launch reuses owner'
 Check ($second.process.WaitForExit(2000)) 'Duplicate process exits'
 Start-Sleep -Milliseconds 150;$state=ReadResult $first $true
 Check $state.visible 'Duplicate restores hidden main window'
 $same=Launch $a $scope;$r=ReadResult $same
 Check ($r.decision -eq 'reused') 'Same-directory launch reuses owner'
 $isolated=Launch $b $scope @('--isolated-instance');$r=ReadResult $isolated;ReadResult $isolated $true | Out-Null
 Check ($r.decision -eq 'start') 'Explicit test isolation can coexist'
 $isolatedDuplicate=Launch $b $scope @('--isolated-instance');$r=ReadResult $isolatedDuplicate
 Check ($r.decision -eq 'reused' -and $r.target -eq $isolated.process.Id) 'Same isolated directory deduplicates'
 $normal=Launch $b $scope;$r=ReadResult $normal
 Check ($r.decision -eq 'reused' -and $r.target -eq $first.process.Id) 'Normal launch ignores isolated test'
 StopOwned $isolated;StopOwned $first
 $scope=[guid]::NewGuid().ToString('N');$legacy=Launch $b $scope @('--legacy');ReadResult $legacy $true|Out-Null
 $new=Launch $a $scope;$r=ReadResult $new
 Check ($r.decision -eq 'reused' -and $r.target -eq $legacy.process.Id) 'Legacy unmarked window is reused'
 StopOwned $legacy
 $scope=[guid]::NewGuid().ToString('N');$raceA=Launch $a $scope @('--delay=500');$raceB=Launch $b $scope @('--delay=500')
 $one=ReadResult $raceA;$two=ReadResult $raceB
 Check (@($one,$two|Where-Object decision -eq 'start').Count -eq 1) 'Concurrent launch elects one owner'
 Check (@($one,$two|Where-Object decision -eq 'reused').Count -eq 1) 'Concurrent loser waits then restores'
 StopOwned $raceA;StopOwned $raceB
 $scope=[guid]::NewGuid().ToString('N');$held=Launch $a $scope @('--held');ReadResult $held|Out-Null
 $blocked=Launch $b $scope @('--wait=200');$r=ReadResult $blocked
 Check ($r.decision -eq 'failed') 'Occupied lease without window cannot spawn a second engine'
 StopOwned $held
 $replacement=Launch $b $scope;Check ((ReadResult $replacement).decision -eq 'start') 'Lease released after process exit'
 StopOwned $replacement
} finally {foreach($item in $owned){StopOwned $item}}
@{passed=$true;checks=$checks;fixtureProcessesExited=@($owned|Where-Object {!$_.process.HasExited}).Count -eq 0} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $output 'acceptance.json') -Encoding utf8
Write-Output "PASS: $($checks.Count) instance checks; all owned fixtures exited"
Write-Output $output
