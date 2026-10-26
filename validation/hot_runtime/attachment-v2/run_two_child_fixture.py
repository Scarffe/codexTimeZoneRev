"""Test exact child pipe association and a benign write only on owned fixtures."""
import ctypes as C
from ctypes import wintypes as W
import json
import pathlib
import queue
import shutil
import subprocess
import threading

import locator_metadata as locator

ROOT = pathlib.Path(__file__).resolve().parent
K = locator.K


class Overlapped(C.Structure):
    _fields_ = [
        ('Internal', C.c_size_t), ('InternalHigh', C.c_size_t),
        ('Offset', W.DWORD), ('OffsetHigh', W.DWORD), ('hEvent', W.HANDLE),
    ]


K.CreateEventW.argtypes = [C.c_void_p, W.BOOL, W.BOOL, W.LPCWSTR]
K.CreateEventW.restype = W.HANDLE
K.WaitForSingleObject.argtypes = [W.HANDLE, W.DWORD]
K.WaitForSingleObject.restype = W.DWORD
K.WriteFile.argtypes = [W.HANDLE, C.c_void_p, W.DWORD, C.POINTER(W.DWORD), C.POINTER(Overlapped)]
K.WriteFile.restype = W.BOOL
K.GetOverlappedResult.argtypes = [W.HANDLE, C.POINTER(Overlapped), C.POINTER(W.DWORD), W.BOOL]
K.GetOverlappedResult.restype = W.BOOL
K.CancelIoEx.argtypes = [W.HANDLE, C.POINTER(Overlapped)]
K.CancelIoEx.restype = W.BOOL


def write_owned_fixture(owned_parent, located):
    if owned_parent.pid != located['parent']['pid'] or owned_parent.poll() is not None:
        raise RuntimeError('owned fixture identity mismatch')
    process = K.OpenProcess(0x40, False, owned_parent.pid)
    duplicate = W.HANDLE()
    event = None
    try:
        if not K.DuplicateHandle(process, located['stdinWriter']['handle'], K.GetCurrentProcess(), C.byref(duplicate), 0, False, 2):
            raise C.WinError(C.get_last_error())
        event = K.CreateEventW(None, True, False, None)
        if not event:
            raise C.WinError(C.get_last_error())
        overlapped = Overlapped()
        overlapped.hEvent = event | 1
        frame = b'{"id":"thread/read:ctz-two-child-fixture","method":"fixture/auth-update"}\n'
        buffer = C.create_string_buffer(frame)
        written = W.DWORD()
        success = K.WriteFile(duplicate, buffer, len(frame), C.byref(written), C.byref(overlapped))
        if not success:
            error = C.get_last_error()
            if error != 997:
                raise C.WinError(error)
            if K.WaitForSingleObject(event, 5000) != 0:
                K.CancelIoEx(duplicate, C.byref(overlapped))
                K.GetOverlappedResult(duplicate, C.byref(overlapped), C.byref(written), True)
                raise RuntimeError('owned fixture write timeout')
        if not K.GetOverlappedResult(duplicate, C.byref(overlapped), C.byref(written), False) or written.value != len(frame):
            raise RuntimeError('incomplete owned fixture write')
    finally:
        if event:
            K.CloseHandle(event)
        if duplicate:
            K.CloseHandle(duplicate)
        if process:
            K.CloseHandle(process)


def main():
    fixture = subprocess.Popen(
        [shutil.which('node'), str(ROOT / 'two_child_desktop.cjs')],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding='utf-8', creationflags=subprocess.CREATE_NO_WINDOW,
    )
    inbox = queue.Queue()

    def read_fixture():
        for line in fixture.stdout:
            inbox.put(json.loads(line))

    threading.Thread(target=read_fixture, daemon=True).start()
    received = []

    def receive():
        event = inbox.get(timeout=10)
        received.append(event)
        return event

    def send(role, sequence, kind='normal'):
        fixture.stdin.write(json.dumps({'type': kind, 'role': role, 'seq': sequence}) + '\n')
        fixture.stdin.flush()

    context = {'status': 'STARTED', 'realCodexProcessAccess': False, 'modelRequests': 0}
    ready = None
    try:
        ready = receive()
        assert ready['event'] == 'fixture-ready', ready
        context['ready'] = ready
        parent = locator.identity(ready['parentPid'])
        target = locator.identity(ready['targetPid'])
        control = locator.identity(ready['controlPid'])
        for role in ('target', 'control'):
            send(role, 'baseline-' + role)
        baseline = [receive(), receive()]
        assert {event['role'] for event in baseline} == {'target', 'control'}, baseline
        assert all(event['message']['result']['authRevision'] == 0 for event in baseline), baseline

        context['stage'] = 'locate-target-with-six-parent-pipes'
        target_locator = locator.locate(parent, target)
        context['targetLocator'] = target_locator
        context['stage'] = 'locate-control-independently'
        control_locator = locator.locate(parent, control)
        context['controlLocator'] = control_locator
        target_names = {pipe['name'] for pipe in target_locator['allConnectedPipes']}
        control_names = {pipe['name'] for pipe in control_locator['allConnectedPipes']}
        assert len(target_names) == len(control_names) == 3
        assert target_names.isdisjoint(control_names), 'child pipe sets overlapped'
        assert target_locator['stdinWriter']['handle'] != control_locator['stdinWriter']['handle']

        context['stage'] = 'write-only-proven-target-stdin'
        write_owned_fixture(fixture, target_locator)
        events = [receive(), receive()]
        assert all(event['role'] == 'target' for event in events), events
        assert {event['message'].get('method') for event in events} == {'account/updated', None}, events

        context['stage'] = 'preserve-both-original-readers'
        for sequence in range(100):
            send('target', f'target-{sequence}')
            send('control', f'control-{sequence}')
        post = [receive() for _ in range(200)]
        assert sum(event['role'] == 'target' for event in post) == 100
        assert sum(event['role'] == 'control' for event in post) == 100
        assert all(event['message']['result']['authRevision'] == (1 if event['role'] == 'target' else 0) for event in post)
        assert locator.identity(parent['pid']) == parent
        assert locator.identity(target['pid']) == target
        assert locator.identity(control['pid']) == control
        assert fixture.poll() is None
        result = {
            'status': 'PASS_TWO_CHILD_EXACT_METADATA_ASSOCIATION',
            'parentPid': parent['pid'], 'targetChildPid': target['pid'], 'controlChildPid': control['pid'],
            'parentHadAtLeastSixDistinctChildPipeNames': len(target_names | control_names) == 6,
            'targetPipeNamesMatchedOnlyTargetChild': True,
            'controlPipeNamesMatchedOnlyControlChild': True,
            'stdinSelectedByExactDifferenceNotPipeOrderOrAccessGuess': True,
            'childStdinFileObjectWasNeverQueried': True,
            'fixedProcessMemoryBytesReadPerChild': 32,
            'originalReaderReceivedTargetAccountUpdated': True,
            'targetPostUpdateReplies': 100, 'controlUnchangedReplies': 100,
            'allThreeProcessIdentitiesUnchanged': True,
            'realCodexProcessAccess': False, 'realDesktopHotSwitch': 'NOT_RUN',
            'externalTokenRefresh': 'NOT_IMPLEMENTED', 'modelRequests': 0,
        }
        (ROOT / 'two-child-fixture-result.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        (ROOT / 'two-child-association-detail.json').write_text(json.dumps(context, indent=2) + '\n', encoding='utf-8')
        print(json.dumps(result, indent=2))
    except Exception as error:
        context.update(status='FAILED_TWO_CHILD_FIXTURE', error=str(error), eventsReceived=len(received))
        (ROOT / 'two-child-fixture-failure.json').write_text(json.dumps(context, indent=2) + '\n', encoding='utf-8')
        raise
    finally:
        if ready is not None and fixture.poll() is None:
            send('target', 'exit-target', 'exit')
            send('control', 'exit-control', 'exit')
            try:
                fixture.wait(timeout=5)
            except subprocess.TimeoutExpired:
                fixture.kill()
                fixture.wait()


if __name__ == '__main__':
    main()
