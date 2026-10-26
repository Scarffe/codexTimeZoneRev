# Desktop runtime observer

Windows x64 resident observer used by the finite account-provider helper. It is
not a standalone account switch, injector UI, or model transport. The broker
chooses only the fixed Desktop `chrome.dll` or the owned Node acceptance role
and supplies the explicit, versioned process/module/stdio proof in
`v4_bootstrap_api.h`. No startup environment or client restart is required.

The IAT hooks call the original `ReadFile`/`GetOverlappedResult`/`WriteFile` and preserve
their arguments, completed buffers, return values and LastError. A constant
storage JSONL projection keeps selected typed IDs, registered identity fields and
thread status/attention metadata;
large unrelated results and unknown values are skipped. The original client
remains the only pipe reader. Overflow or unsupported completion coverage is
reported as a gap, never fabricated as a successful credential update.

`Stop` restores this observer's IAT slots and page protections. Code remains
resident; physical unload is deliberately absent. The native helper must retain
authentication ownership while the target uses its external-token provider.
Stopping observation is not an authentication handback.

Build with CMake and the Windows x64 MSVC toolchain. Outputs belong in the CMake
build directory. Owned-process acceptance drivers and immutable run evidence
are maintained separately; passing Node/libuv acceptance does not prove actual
Desktop behavior. The original Desktop has passed reversible read-only observation and a fixed
read-probe writer proof. Real credential switching is a separate human acceptance.
Metadata loaded-list/read snapshots do not resume or subscribe to threads; their
queue loss never disables the separate authentication refresh path.
