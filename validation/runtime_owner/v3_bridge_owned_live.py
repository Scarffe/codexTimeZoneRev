"""Production bridge PollLive + auth ABI2 on this driver's own pinned Node.

No PID selector, Desktop discovery, SDK, credentials, login or model request.
The Node parent remains the sole child-stdout reader and verifies full SHA256.
"""
import argparse
import ctypes as C
from ctypes import wintypes as W
import hashlib
import json
import os
from pathlib import Path
import queue
import secrets
import subprocess
import sys
import threading
import time
sys.dont_write_bytecode = True
import run_owned_node_observer as base
from v3_owned_live import Event, LiveEvent

ROOT = Path(__file__).resolve().parent
SENTINEL = b'SYNTHETIC_LIVE_BODY_ea04b9'

class OwnedTarget(C.Structure):
    _fields_ = [('ownerPid', W.DWORD), ('childPid', W.DWORD),
                ('ownerCreation', C.c_uint64), ('childCreation', C.c_uint64)]

class State(C.Structure):
    _fields_ = [(name, W.DWORD) for name in ('bytes', 'version', 'ownerPid', 'childPid')] + [
        ('ownerCreation', C.c_uint64), ('childCreation', C.c_uint64)] + [
        (name, W.DWORD) for name in ('attached', 'targetAlive', 'writeReady', 'coverageUnknown',
        'framesObserved', 'eventDrops', 'iatRestored', 'protectionRestored',
        'writesCompleted', 'writePending', 'apiInvariant', 'pendingReadCompleted')]

class LiveState(C.Structure):
    _fields_ = [('bytes', W.DWORD), ('version', W.DWORD), ('generation', C.c_uint64)] + [
        (name, W.DWORD) for name in ('coverageFlags', 'eventDrops', 'eventsPublished',
                                  'outstanding', 'targetAlive', 'captureEnabled')]

assert C.sizeof(OwnedTarget) == 24 and C.sizeof(State) == 80
assert C.sizeof(LiveState) == 40 and C.sizeof(LiveEvent) == 248 and C.sizeof(Event) == 664

def run(args):
    receipt = Path(args.receipt)
    if receipt.exists():
        raise RuntimeError('preserve_existing_receipt')
    result = {'pass': False, 'actualDesktopAccess': False, 'modelRequests': 0,
              'credentialReads': 0, 'helperSideWrites': 0, 'authWrites': 0,
              'productionGate': True, 'stage': 0}
    process = None
    bridge = None
    handle = C.c_void_p()
    stopped = False
    parent = child = None
    try:
        library = Path(args.bridge).resolve(strict=True)
        observer = Path(args.observer).resolve(strict=True)
        if library.name.casefold() != 'v3_runtime_bridge_owned.dll' or observer.name.casefold() != 'v3_node_observer.dll':
            raise RuntimeError('fixed_owned_artifact_required')
        if hashlib.sha256(base.APPROVED_NODE.read_bytes()).hexdigest() != base.NODE_SHA256:
            raise RuntimeError('owned_node_hash_changed')
        bridge = C.WinDLL(str(library))
        bridge.CtzBridgeAbiVersion.restype = W.DWORD
        if bridge.CtzBridgeAbiVersion() != 2:
            raise RuntimeError('auth_abi_changed')
        bridge.CtzBridgeAttachOwnedProductionGate.argtypes = [C.POINTER(OwnedTarget), W.LPCWSTR, C.POINTER(C.c_void_p)]
        bridge.CtzBridgeAttachOwnedProductionGate.restype = W.DWORD
        bridge.CtzBridgeStatus.argtypes = [C.c_void_p, C.POINTER(State)]
        bridge.CtzBridgeStatus.restype = W.DWORD
        bridge.CtzBridgePollV2.argtypes = [C.c_void_p, C.POINTER(Event)]
        bridge.CtzBridgePollV2.restype = W.DWORD
        bridge.CtzBridgePollLive.argtypes = [C.c_void_p, C.POINTER(LiveEvent), C.POINTER(LiveState)]
        bridge.CtzBridgePollLive.restype = W.DWORD
        bridge.CtzBridgeReadWatermark.argtypes = [C.c_void_p, C.POINTER(C.c_uint64)]
        bridge.CtzBridgeReadWatermark.restype = W.DWORD
        for name in ('CtzBridgeStop', 'CtzBridgeClose'):
            function = getattr(bridge, name)
            function.argtypes = [C.c_void_p]
            function.restype = W.DWORD
        work = ROOT / ('v3-bridge-owned-temp-' + secrets.token_hex(8))
        work.mkdir()
        system = os.environ.get('SystemRoot', r'C:\Windows')
        env = {'SystemRoot': system, 'WINDIR': system, 'TEMP': str(work), 'TMP': str(work)}
        process = subprocess.Popen([str(base.APPROVED_NODE), str(ROOT / 'v3_live_parent.cjs')],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding='utf8', env=env, cwd=ROOT, creationflags=subprocess.CREATE_NO_WINDOW)
        inbox = queue.Queue()
        def read_control():
            for line in process.stdout:
                try:
                    inbox.put(json.loads(line))
                except ValueError:
                    inbox.put(None)
        threading.Thread(target=read_control, daemon=True).start()
        spawned = inbox.get(timeout=10)
        if not spawned or spawned.get('event') != 'spawned' or spawned.get('parentPid') != process.pid:
            raise RuntimeError('owned_startup')
        parent, child = base.locator.identity(process.pid), base.locator.identity(spawned['childPid'])
        if parent['parentPid'] != os.getpid() or child['parentPid'] != parent['pid']:
            raise RuntimeError('owned_parentage')
        def pin():
            if process.poll() is not None or not base.locator.pinned_equal(base.locator.identity(parent['pid']), parent) or not base.locator.pinned_equal(base.locator.identity(child['pid']), child):
                raise RuntimeError('owned_identity_changed')
        def operation(function, *values):
            pin()
            value = function(*values)
            pin()
            return value
        pin()
        process.stdin.write('warmup\n')
        process.stdin.flush()
        baseline = inbox.get(timeout=10)
        if baseline.get('event') != 'baseline-complete' or baseline.get('frames') != 3 or not baseline.get('byteEqual') or not baseline.get('hashEqual'):
            raise RuntimeError('baseline')
        result.update(stage=1, baselineRpcCount=3)
        target = OwnedTarget(parent['pid'], child['pid'], parent['created'], child['created'])
        status = operation(bridge.CtzBridgeAttachOwnedProductionGate, C.byref(target), str(observer), C.byref(handle))
        result['attachStatus'] = int(status)
        if status != 1 or not handle:
            raise RuntimeError('production_attach_failed')
        state = State()
        state.bytes, state.version = C.sizeof(state), 1
        if operation(bridge.CtzBridgeStatus, handle, C.byref(state)) != 1 or not state.attached or state.writeReady:
            raise RuntimeError('initial_state')
        live_state = LiveState()
        live_state.bytes, live_state.version = C.sizeof(live_state), 1
        event = LiveEvent()
        status = operation(bridge.CtzBridgePollLive, handle, C.byref(event), C.byref(live_state))
        initial_unknown = status == 2 and live_state.coverageFlags == 3 and live_state.targetAlive and live_state.captureEnabled and not live_state.eventsPublished
        if not initial_unknown:
            raise RuntimeError('initial_live_gap_contract')
        generation = int(live_state.generation)
        result.update(stage=2, authAbiVersion=2, initialLiveUnknown=True)
        pin()
        process.stdin.write('probe\n')
        process.stdin.flush()
        pin()
        probe = inbox.get(timeout=20)
        if probe.get('event') != 'probe-complete' or probe.get('frames') != 19 or probe.get('bytes') != 265074 or not probe.get('byteEqual') or not probe.get('hashEqual') or not probe.get('stderrEmpty') or probe.get('replyCount') != 2:
            raise RuntimeError('original_reader_stream')
        live_events = []
        while True:
            event = LiveEvent()
            status = operation(bridge.CtzBridgePollLive, handle, C.byref(event), C.byref(live_state))
            if status == 2:
                break
            if status != 1 or len(live_events) >= 16:
                raise RuntimeError('poll_live_failed')
            live_events.append(event)
        kinds = [1, 2, 4, 7, 4, 4, 5, 8, 5, 6, 1, 1, 3, 3, 3]
        valid_kinds = len(live_events) == 15 and [e.kind for e in live_events] == kinds
        valid_sequence = all(e.sequence == i + 1 and e.generation == generation for i, e in enumerate(live_events))
        contexts = all(bytes(e.threadId) == b'thread-A' for e in live_events)
        exact_reply = valid_kinds and live_events[2].requestId.kind == 1 and live_events[2].requestId.number == 17 and live_events[3].requestId.kind == 1 and live_events[3].requestId.number == 17 and live_state.outstanding == 4
        lifecycle = valid_kinds and [live_events[i].lifecycle for i in (1, 11, 12, 13, 14)] == [5, 2, 7, 8, 6]
        blocking = valid_kinds and live_events[6].flags & 48 == 48 and live_events[8].flags & 16 and not live_events[8].flags & 32 and live_events[9].flags & 8 and not bytes(live_events[9].turnId)
        snapshot = valid_kinds and live_events[0].attention == 1 and live_events[10].attention == 3 and live_events[11].kind == 1
        auth_events = []
        while True:
            event = Event()
            status = operation(bridge.CtzBridgePollV2, handle, C.byref(event))
            if status == 2:
                break
            if status != 1 or len(auth_events) >= 16:
                raise RuntimeError('poll_auth_failed')
            auth_events.append(event)
        auth_valid = [e.kind for e in auth_events] == [1, 2] and all(e.generation == generation and e.sequence == i + 1 for i, e in enumerate(auth_events))
        private_absent = all(SENTINEL not in bytes(e) for e in live_events + auth_events)
        auth_private = all(not e.emailBytes and not e.planBytes and not e.accountIdBytes and not bytes(e.email) and not bytes(e.plan) and not bytes(e.accountId) for e in auth_events)
        watermark = C.c_uint64()
        if operation(bridge.CtzBridgeReadWatermark, handle, C.byref(watermark)) != 1:
            raise RuntimeError('auth_watermark')
        if operation(bridge.CtzBridgeStatus, handle, C.byref(state)) != 1:
            raise RuntimeError('final_status')
        live_valid = live_state.coverageFlags == 3 and not live_state.eventDrops and live_state.eventsPublished == 15 and live_state.targetAlive and live_state.captureEnabled
        result.update(stage=3, originalReaderFrames=19, originalReaderBytes=265074, originalReaderHashEqual=True,
            liveEvents=len(live_events), liveKindsValid=valid_kinds, liveSequenceValid=valid_sequence,
            liveContextsValid=contexts, exactTypedReply=exact_reply, lifecycleDistinct=lifecycle,
            blockingDistinct=bool(blocking), attentionSnapshots=snapshot, liveCoverageFlags=int(live_state.coverageFlags),
            liveEventDrops=int(live_state.eventDrops), authEvents=len(auth_events), authEventsValid=auth_valid,
            independentAuthWatermark=watermark.value == 2, privateBodyExcluded=private_absent,
            authIdentityExcluded=auth_private, writerReady=bool(state.writeReady), apiInvariant=bool(state.apiInvariant),
            identitiesUnchanged=True, pendingReadCompletionProven=bool(state.pendingReadCompleted),
            actualLiveCoverageRun=False)
        result['pass'] = bool(valid_kinds and valid_sequence and contexts and exact_reply and lifecycle and blocking and snapshot and auth_valid and private_absent and auth_private and live_valid and watermark.value == 2 and state.writeReady and not state.coverageUnknown and state.framesObserved == 19 and not state.eventDrops and state.apiInvariant and not state.writesCompleted and not state.writePending)
        deadline = time.monotonic() + 3
        while True:
            status = operation(bridge.CtzBridgeStop, handle)
            if status != 21 or time.monotonic() >= deadline:
                break
            time.sleep(.01)
        result['stopStatus'] = int(status)
        stopped = status == 1
        if operation(bridge.CtzBridgeStatus, handle, C.byref(state)) != 1:
            raise RuntimeError('stopped_status')
        result['iatRestored'], result['protectionRestored'] = bool(state.iatRestored), bool(state.protectionRestored)
        result['pass'] = result['pass'] and stopped and bool(state.iatRestored) and bool(state.protectionRestored)
        close = operation(bridge.CtzBridgeClose, handle)
        result['closeStatus'] = int(close)
        result['pass'] = result['pass'] and close == 1
        if close == 1:
            handle = C.c_void_p()
        result['observerSha256'] = hashlib.sha256(observer.read_bytes()).hexdigest()
        result['bridgeSha256'] = hashlib.sha256(library.read_bytes()).hexdigest()
    except Exception as error:
        result['failure'] = True
        result['errorKind'] = type(error).__name__
        result['windowsError'] = int(getattr(error, 'winerror', 0) or 0)
    finally:
        if handle and bridge:
            if not stopped:
                try:
                    result['cleanupStopStatus'] = int(bridge.CtzBridgeStop(handle))
                except Exception:
                    pass
        if process and process.poll() is None:
            try:
                process.stdin.write('exit\n')
                process.stdin.flush()
                process.wait(timeout=5)
            except Exception:
                process.kill()
                process.wait(timeout=5)
        if handle and bridge:
            try:
                result['cleanupCloseStatus'] = int(bridge.CtzBridgeClose(handle))
            except Exception:
                pass
        if process:
            result['ownedExitZero'] = process.returncode == 0
            result['pass'] = result['pass'] and result['ownedExitZero']
    encoded = json.dumps(result, separators=(',', ':')) + '\n'
    receipt.write_text(encoded, encoding='utf8')
    print(encoded, end='')
    return 0 if result['pass'] else 1

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--bridge', required=True)
    parser.add_argument('--observer', required=True)
    parser.add_argument('--receipt', required=True)
    raise SystemExit(run(parser.parse_args()))
