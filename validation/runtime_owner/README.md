# Runtime-owner acceptance

Production sources are `native/desktop_runtime_bridge` and
`native/desktop_runtime_observer`. Build companions with
`scripts/build-runtime-owner.ps1` after building the Rust release helper.
The normal DLL exposes no owned-process selector.

`live_projection_contract.cpp` exercises the exact production projector in
memory, including the independent live overflow/auth path. The Python owned
drivers launch only their own pinned Node parent and synthetic server after
three normal requests; the parent's original reader verifies the entire stream
against its SHA256 oracle. They do not attach to Desktop or read credentials.

For the owned bridge test, build with `CTZ_BRIDGE_OWNED_TEST=ON`, place the
metadata executable beside the DLL, and use a new test directory with the
driver's `v3_runtime_bridge_owned.dll` / `v3_node_observer.dll` names. Run
`v3_bridge_owned_live.py --bridge <absolute path> --observer <absolute path>
--receipt <new absolute JSON path>`. The drivers retain their fixed local Node
path/hash and are machine-specific acceptance utilities, not shipped assets.

Owned Node PASS is not actual Desktop PASS. Real Desktop receipts and the
separately bounded read-only probe are kept under the ignored evidence directory.
Actual model requests and billing attribution are outside these tests.
