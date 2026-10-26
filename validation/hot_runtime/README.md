# Runtime attachment research, not a delivered account switcher

These frozen source copies preserve the mechanisms actually tested in the isolated workspace. SOURCE-HASHES.json links each file to its tested source. They are not loaded by the production application. Do not package fixtures or local receipts as authentication functionality.

| Mechanism | Observed evidence | Remaining boundary |
| --- | --- | --- |
| Existing stdio writer duplication | Owned C++/Node parent retains its original reader and receives a synthetic auth notification plus 101 replies | Not authentication; current Desktop has received no writes |
| Exact standard-pipe association | Two children under one parent remain separate; fixed PEB standard-handle metadata, pipe process membership and stdout/stderr name subtraction identify one writer | File-process membership can include inherited descendants; incomplete metadata-query coverage cannot authorize a real write |
| Self-IAT observer | Immediate ReadFile and pending/original GetOverlappedResult paths preserve all original bytes, API behavior and protections; typed refresh IDs pass a separate queue | No real-process injection or actual credentials |
| Owned Node/libuv observer | Node 24.19.0 / libuv 1.52.1: original 9-frame/850-byte stream preserved; 2 sanitized refresh events and replies; logical Stop restores IAT and protections | Installed Desktop static Node candidate differs at 24.22.1; Node run hit immediate reads and zero-byte readiness, not pending GOR; bootstrap still uses fixture environment |

The current Desktop was inspected only for pinned process identity, 32 bytes of standard-handle metadata, pipe metadata and mitigation flags. No stdout payload was read, no credential file read, no pipe written, and no DLL injected into it. Exact observations remain under the ignored environment/hot-global-20261026-a evidence directory.

The next prototype removes environment bootstrap by passing explicit Start configuration to an already established owned Node connection. Actual current-Desktop attachment, credential transfer, observed identity transition, refresh continuity and provider lifecycle are still required. Production account/logout is not a harmless restoration operation: the fixed SDK clears normal stores. A lasting external-token connection needs a live refresh owner or a separately proved handback.

Build and run each finite fixture using its README and a new output directory. The Node broker deliberately accepts only its own freshly created, pinned runtime, not an arbitrary target PID. Fixture success must never be relabeled as a real desktop account switch.
