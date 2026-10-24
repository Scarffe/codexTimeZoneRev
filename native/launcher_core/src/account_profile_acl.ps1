# Embedded, fixed ACL program. Path arrives through an environment value, never code.
# Directory protection is required; CLI-created children can inherit the same user-only rule.
$ErrorActionPreference = 'Stop'
$p = $env:CTZ_PROFILE_ACL_PATH
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
function Check($a, $protected) {
    if ($a.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value -or
        ($protected -and !$a.AreAccessRulesProtected)) { exit 3 }
    $rules = @($a.Access)
    if ($rules.Count -ne 1) { exit 4 }
    foreach ($r in $rules) {
        if ($r.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value -or
            $r.AccessControlType -ne 'Allow' -or
            ($r.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne
                [Security.AccessControl.FileSystemRights]::FullControl) { exit 5 }
    }
}
$a = [IO.Directory]::GetAccessControl($p)
if ($env:CTZ_PROFILE_ACL_CREATE -eq '1') {
    $a.SetAccessRuleProtection($true, $false)
    foreach ($r in @($a.Access)) { $a.RemoveAccessRuleSpecific($r) }
    $a.SetOwner($sid)
    $a.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    [IO.Directory]::SetAccessControl($p, $a)
    $a = [IO.Directory]::GetAccessControl($p)
}
Check $a $true
if ($env:CTZ_PROFILE_ACL_TREE -eq '1') {
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($p)
    while ($pending.Count -gt 0) {
        $parent = $pending.Pop()
        foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($parent)) {
            $attributes = [IO.File]::GetAttributes($child)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) { exit 6 }
            if ($attributes -band [IO.FileAttributes]::Directory) {
                $v = [IO.Directory]::GetAccessControl($child)
                $pending.Push($child)
            } else {
                $v = [IO.File]::GetAccessControl($child)
            }
            Check $v $false
        }
    }
}
