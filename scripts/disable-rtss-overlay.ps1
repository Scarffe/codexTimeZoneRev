param([Parameter(Mandatory)][string]$RtssDirectory)
$ErrorActionPreference = 'Stop'
# RTSS SDK: RTSSProfileInterface.h, AppDetectionLevel=0 means detection None.
# Apply only to this executable, never the global profile or other applications.
$library = Join-Path $RtssDirectory 'RTSSHooks64.dll'
if (!(Test-Path -LiteralPath $library)) { throw "RTSS library not found: $library" }
$profiles = Join-Path $RtssDirectory 'Profiles'
$profile = Join-Path $profiles 'codex_timezone.exe.cfg'
$globalProfile = Join-Path $profiles 'Global'
$globalHash = (Get-FileHash -LiteralPath $globalProfile).Hash
$backup = Join-Path (Split-Path $PSScriptRoot -Parent) ('environment/rtss-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
if (Test-Path -LiteralPath $profile) {
    Copy-Item -LiteralPath $profile -Destination (Join-Path $backup 'codex_timezone.exe.cfg')
} else {
    'No application profile existed. To undo, remove codex_timezone.exe in RTSS application list.' | Set-Content (Join-Path $backup 'no-previous-profile.txt')
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RtssLauncherProfile {
    [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet=CharSet.Ansi)]
    private delegate void Profile(string name);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet=CharSet.Ansi)]
    private delegate int Property(string name, ref uint value, uint size);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void Update();
    public static void Disable(string path) {
        var module = NativeLibrary.Load(path);
        try {
            var load = Marshal.GetDelegateForFunctionPointer<Profile>(NativeLibrary.GetExport(module, "LoadProfile"));
            var save = Marshal.GetDelegateForFunctionPointer<Profile>(NativeLibrary.GetExport(module, "SaveProfile"));
            var set = Marshal.GetDelegateForFunctionPointer<Property>(NativeLibrary.GetExport(module, "SetProfileProperty"));
            var get = Marshal.GetDelegateForFunctionPointer<Property>(NativeLibrary.GetExport(module, "GetProfileProperty"));
            var update = Marshal.GetDelegateForFunctionPointer<Update>(NativeLibrary.GetExport(module, "UpdateProfiles"));
            load("codex_timezone.exe");
            uint disabled = 0;
            if (set("AppDetectionLevel", ref disabled, 4) == 0 || set("EnableOSD", ref disabled, 4) == 0)
                throw new Exception("RTSS refused application-specific settings.");
            save("codex_timezone.exe");
            update();
            load("codex_timezone.exe");
            uint detection = 99, osd = 99;
            if (get("AppDetectionLevel", ref detection, 4) == 0 || get("EnableOSD", ref osd, 4) == 0 || detection != 0 || osd != 0)
                throw new Exception("RTSS profile verification failed.");
        } finally { NativeLibrary.Free(module); }
    }
}
'@
[RtssLauncherProfile]::Disable($library)
if ((Get-FileHash -LiteralPath $globalProfile).Hash -ne $globalHash) { throw 'RTSS global profile changed unexpectedly.' }
Write-Output "Disabled RTSS detection and OSD for codex_timezone.exe only. Global settings unchanged. Backup: $backup"
Write-Output 'Restart the launcher to remove an already injected overlay module.'
