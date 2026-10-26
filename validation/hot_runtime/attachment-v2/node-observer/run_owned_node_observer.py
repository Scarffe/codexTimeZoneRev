"""Owned-only Node IAT demonstration. No PID option and no existing-process attach."""
import argparse
import ctypes as C
from ctypes import wintypes as W
import hashlib
import json
import os
from pathlib import Path
import queue
import secrets
import struct
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parent
APPROVED_NODE = Path(r'C:\Users\FixtureUser\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe')
NODE_SHA256 = '3602f2bb1a10f2cbab4c36886218a33c1ab3db87290e73b033c46c77147d0237'
SENTINEL = b'SYNTHETIC_PRIVATE_VALUE_6d3f1a'
sys.path.insert(0, str(ROOT.parent))
sys.dont_write_bytecode = True  # Do not modify the frozen locator's sibling cache.
import locator_metadata as locator

K = C.WinDLL('kernel32', use_last_error=True)
SIZE = C.c_size_t
PTR = C.c_void_p


class Event(C.Structure):
    _fields_ = [('method', W.DWORD), ('kind', W.DWORD), ('number', C.c_int64),
                ('length', W.DWORD), ('text', C.c_char * 64)]


class Shared(C.Structure):
    _fields_ = [(name, W.DWORD) for name in ('magic', 'version', 'bytes', 'brokerPid', 'nodePid', 'childPid')] + [
        ('readerHandle', C.c_uint64), ('nonce', C.c_char * 40)] + [
        (name, W.LONG) for name in ('state', 'enabled', 'head', 'tail', 'drops', 'lines', 'rejects',
        'duplicateRejects', 'immediate', 'pending', 'gor', 'gorAborted', 'zeroReads', 'apiInvariant',
        'coalesced', 'fragmented', 'iatRestored', 'protectionRestored')] + [('events', Event * 16)]


class Overlapped(C.Structure):
    _fields_ = [('Internal', SIZE), ('InternalHigh', SIZE), ('Offset', W.DWORD),
                ('OffsetHigh', W.DWORD), ('hEvent', W.HANDLE)]


class ModuleEntry(C.Structure):
    _fields_ = [('dwSize', W.DWORD), ('th32ModuleID', W.DWORD), ('th32ProcessID', W.DWORD),
                ('GlblcntUsage', W.DWORD), ('ProccntUsage', W.DWORD), ('modBaseAddr', PTR),
                ('modBaseSize', W.DWORD), ('hModule', W.HMODULE),
                ('szModule', W.WCHAR * 256), ('szExePath', W.WCHAR * 260)]


assert C.sizeof(PTR) == 8 and C.sizeof(Event) == 88 and Shared.events.offset == 144 and C.sizeof(Shared) == 1552
assert C.sizeof(Overlapped) == 32 and C.sizeof(ModuleEntry) == 1080
for name, args, result in [
    ('CreateFileMappingW', [W.HANDLE, PTR, W.DWORD, W.DWORD, W.DWORD, W.LPCWSTR], W.HANDLE),
    ('MapViewOfFile', [W.HANDLE, W.DWORD, W.DWORD, W.DWORD, SIZE], PTR),
    ('UnmapViewOfFile', [PTR], W.BOOL), ('CloseHandle', [W.HANDLE], W.BOOL),
    ('VirtualAllocEx', [W.HANDLE, PTR, SIZE, W.DWORD, W.DWORD], PTR),
    ('VirtualFreeEx', [W.HANDLE, PTR, SIZE, W.DWORD], W.BOOL),
    ('WriteProcessMemory', [W.HANDLE, PTR, PTR, SIZE, C.POINTER(SIZE)], W.BOOL),
    ('CreateRemoteThread', [W.HANDLE, PTR, SIZE, PTR, PTR, W.DWORD, C.POINTER(W.DWORD)], W.HANDLE),
    ('WaitForSingleObject', [W.HANDLE, W.DWORD], W.DWORD),
    ('GetExitCodeThread', [W.HANDLE, C.POINTER(W.DWORD)], W.BOOL),
    ('CreateToolhelp32Snapshot', [W.DWORD, W.DWORD], W.HANDLE),
    ('Module32FirstW', [W.HANDLE, C.POINTER(ModuleEntry)], W.BOOL),
    ('Module32NextW', [W.HANDLE, C.POINTER(ModuleEntry)], W.BOOL),
    ('GetModuleHandleW', [W.LPCWSTR], W.HMODULE),
    ('GetProcAddress', [W.HMODULE, C.c_char_p], PTR),
    ('GetModuleHandleExW', [W.DWORD, PTR, C.POINTER(W.HMODULE)], W.BOOL),
    ('GetModuleFileNameW', [W.HMODULE, W.LPWSTR, W.DWORD], W.DWORD),
    ('GetCurrentProcess', [], W.HANDLE),
    ('DuplicateHandle', [W.HANDLE, W.HANDLE, W.HANDLE, C.POINTER(W.HANDLE), W.DWORD, W.BOOL, W.DWORD], W.BOOL),
    ('CreateEventW', [PTR, W.BOOL, W.BOOL, W.LPCWSTR], W.HANDLE),
    ('WriteFile', [W.HANDLE, PTR, W.DWORD, C.POINTER(W.DWORD), C.POINTER(Overlapped)], W.BOOL),
    ('GetOverlappedResult', [W.HANDLE, C.POINTER(Overlapped), C.POINTER(W.DWORD), W.BOOL], W.BOOL),
    ('CancelIoEx', [W.HANDLE, C.POINTER(Overlapped)], W.BOOL),
]:
    function = getattr(K, name)
    function.argtypes, function.restype = args, result


def required(value):
    if not value:
        raise C.WinError(C.get_last_error())
    return value


def exports(path):
    data = path.read_bytes()
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    optional = pe + 24
    if data[pe:pe + 4] != b'PE\0\0' or struct.unpack_from('<H', data, optional)[0] != 0x20b:
        raise RuntimeError('x64 DLL required')
    count, optional_size = struct.unpack_from('<H', data, pe + 6)[0], struct.unpack_from('<H', data, pe + 20)[0]
    sections = [struct.unpack_from('<IIII', data, optional + optional_size + i * 40 + 8) for i in range(count)]

    def raw(rva):
        return next(pointer + rva - va for virtual_size, va, raw_size, pointer in sections if va <= rva < va + max(virtual_size, raw_size))

    def cstring(offset):
        return data[offset:data.index(0, offset)].decode('ascii')

    rva = struct.unpack_from('<I', data, optional + 112)[0]
    table = struct.unpack_from('<IIHHIIIIIII', data, raw(rva))
    functions, names, ordinals = map(raw, table[8:11])
    result = {}
    for i in range(table[7]):
        name = cstring(raw(struct.unpack_from('<I', data, names + 4 * i)[0]))
        if name in ('Start', 'Stop'):
            ordinal = struct.unpack_from('<H', data, ordinals + i * 2)[0]
            result[name] = struct.unpack_from('<I', data, functions + ordinal * 4)[0]
    if set(result) != {'Start', 'Stop'}:
        raise RuntimeError('required DLL exports missing')
    return result


class Owned:
    """A capability bound only to this invocation's Popen and its announced child."""
    def __init__(self, process, child_pid, nonce, shared):
        self.process, self.nonce = process, nonce
        self.shared = shared
        self.remote_timed_out = False
        self.parent = locator.identity(process.pid)
        self.child = locator.identity(child_pid)
        if self.parent['path'].casefold() != str(APPROVED_NODE).casefold() or self.child['path'].casefold() != str(APPROVED_NODE).casefold() or self.child['parentPid'] != process.pid:
            raise RuntimeError('owned process provenance mismatch')
        self.handle = int(process._handle)  # Retained CreateProcess capability, not arbitrary OpenProcess.
        self.operations = 0

    def pin(self):
        generation_matches = bytes(self.shared.nonce) == self.nonce.encode() and self.shared.nodePid == self.parent['pid'] and self.shared.childPid == self.child['pid'] and self.shared.brokerPid == os.getpid()
        if not generation_matches or self.process.poll() is not None or not locator.pinned_equal(locator.identity(self.parent['pid']), self.parent) or not locator.pinned_equal(locator.identity(self.child['pid']), self.child):
            raise RuntimeError('owned identity changed')

    def operation(self, function, *args):
        self.pin()
        value = function(*args)
        error = C.get_last_error()
        self.pin()
        self.operations += 1
        C.set_last_error(error)
        return value

    def modules(self):
        self.pin()
        snapshot = required(K.CreateToolhelp32Snapshot(0x18, self.process.pid))
        if snapshot == C.c_void_p(-1).value:
            raise C.WinError(C.get_last_error())
        result = []
        try:
            entry = ModuleEntry(); entry.dwSize = C.sizeof(entry)
            ok = K.Module32FirstW(snapshot, C.byref(entry))
            while ok:
                result.append((entry.szModule.casefold(), entry.szExePath.casefold(), int(entry.modBaseAddr)))
                ok = K.Module32NextW(snapshot, C.byref(entry))
        finally:
            K.CloseHandle(snapshot)
            self.pin()
        self.operations += 1
        return result

    def remote_thread(self, address, argument=0):
        thread = required(self.operation(K.CreateRemoteThread, self.handle, None, 0, address, argument, 0, None))
        try:
            if self.operation(K.WaitForSingleObject, thread, 10000) != 0:
                self.remote_timed_out = True
                raise TimeoutError('owned remote thread timed out')
            code = W.DWORD()
            required(self.operation(K.GetExitCodeThread, thread, C.byref(code)))
            return code.value  # Status only. Never interpret DWORD as a module base.
        finally:
            K.CloseHandle(thread)

    def load(self, dll):
        address = required(K.GetProcAddress(required(K.GetModuleHandleW('kernel32.dll')), b'LoadLibraryW'))
        owner = W.HMODULE()
        required(K.GetModuleHandleExW(0x6, address, C.byref(owner)))
        owner_path = C.create_unicode_buffer(32768)
        required(K.GetModuleFileNameW(owner, owner_path, len(owner_path)))
        owner_name = Path(owner_path.value).name.casefold()
        owner_remote = [base for name, _, base in self.modules() if name == owner_name]
        if len(owner_remote) != 1:
            raise RuntimeError('LoadLibrary function owner not unique')
        remote_load = owner_remote[0] + int(address) - int(owner.value)
        payload = C.create_unicode_buffer(str(dll))
        byte_count = C.sizeof(payload)
        allocation = required(self.operation(K.VirtualAllocEx, self.handle, None, byte_count, 0x3000, 4))
        try:
            written = SIZE()
            required(self.operation(K.WriteProcessMemory, self.handle, allocation, payload, byte_count, C.byref(written)))
            if written.value != byte_count:
                raise RuntimeError('incomplete owned path copy')
            self.remote_thread(remote_load, allocation)
        finally:
            if not self.remote_timed_out:  # Never free a path buffer a timed-out loader could still use.
                required(self.operation(K.VirtualFreeEx, self.handle, allocation, 0, 0x8000))
        matches = [base for _, path, base in self.modules() if path == str(dll).casefold()]
        if len(matches) != 1:
            raise RuntimeError('owned DLL module missing')
        return matches[0]

    def write_ack(self, parent_writer, identifier):
        duplicate = W.HANDLE(); event = None
        try:
            required(self.operation(K.DuplicateHandle, self.handle, parent_writer, K.GetCurrentProcess(), C.byref(duplicate), 0, False, 2))
            event = required(K.CreateEventW(None, True, False, None))
            overlap = Overlapped(); overlap.hEvent = event | 1  # Suppress original parent's IOCP packet.
            frame = json.dumps({'id': identifier, 'result': {'fixtureAck': True}}, separators=(',', ':')).encode() + b'\n'
            if SENTINEL in frame:
                raise RuntimeError('synthetic private value leaked')
            buffer = C.create_string_buffer(frame); written = W.DWORD()
            ok = self.operation(K.WriteFile, duplicate, buffer, len(frame), C.byref(written), C.byref(overlap))
            if not ok:
                if C.get_last_error() != 997:
                    raise C.WinError(C.get_last_error())
                if self.operation(K.WaitForSingleObject, event, 5000) != 0:
                    self.operation(K.CancelIoEx, duplicate, C.byref(overlap))
                    self.operation(K.GetOverlappedResult, duplicate, C.byref(overlap), C.byref(written), True)
                    raise TimeoutError('owned acknowledgment timed out')
            required(self.operation(K.GetOverlappedResult, duplicate, C.byref(overlap), C.byref(written), False))
            if written.value != len(frame):
                raise RuntimeError('partial owned acknowledgment')
        finally:
            if event: K.CloseHandle(event)
            if duplicate: K.CloseHandle(duplicate)


def run(args):
    result = {'pass': False, 'real_codex_process_access': False, 'real_desktop_attachment_run': False,
              'model_requests': 0, 'credentials_read': False, 'desktop_patch_equivalence_proven': False,
              'cancel_partial_proven': False, 'coverage_unknown': True, 'global_state_coverage_unknown': True, 'stage': 0}
    process = None; mapping = None; view = None; shared = None; owned = None; module = None; stopped = False
    try:
        node, dll = Path(args.node).resolve(strict=True), Path(args.dll).resolve(strict=True)
        if node != APPROVED_NODE.resolve(strict=True) or hashlib.sha256(node.read_bytes()).hexdigest() != NODE_SHA256 or dll != (ROOT / 'owned_node_observer.dll').resolve(strict=True):
            raise RuntimeError('unapproved owned artifact path or build')
        export_rvas = exports(dll)
        nonce = secrets.token_hex(16)
        map_name = 'Local\\CTZOwnedObserver-' + nonce
        mapping = required(K.CreateFileMappingW(C.c_void_p(-1), None, 4, 0, C.sizeof(Shared), map_name))
        if C.get_last_error() == 183:
            raise RuntimeError('owned mapping unexpectedly existed')
        view = required(K.MapViewOfFile(mapping, 0xf001f, 0, 0, C.sizeof(Shared)))
        C.memset(view, 0, C.sizeof(Shared)); shared = Shared.from_address(view)
        shared.magic, shared.version, shared.bytes, shared.brokerPid = 0x4f4e4f42, 1, C.sizeof(Shared), os.getpid()
        shared.nonce = nonce.encode()
        work = ROOT / ('owned-temp-' + nonce); work.mkdir()
        system = os.environ.get('SystemRoot', r'C:\Windows')
        environment = {'SystemRoot': system, 'WINDIR': system, 'TEMP': str(work), 'TMP': str(work),
                       'CTZ_OWNED_NONCE': nonce, 'CTZ_OWNED_NO_CREDENTIALS': '1', 'CTZ_OWNED_OBSERVER_MAP': map_name}
        result['stage'] = 1
        process = subprocess.Popen([str(node), str(ROOT / 'owned_node_parent.cjs')], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8', env=environment,
            cwd=str(ROOT), creationflags=subprocess.CREATE_NO_WINDOW)
        inbox = queue.Queue()

        def control_reader():
            for line in process.stdout:
                try:
                    value = json.loads(line)
                    if value.get('nonce') != nonce or value.get('event') not in ('ready', 'complete', 'extra-bytes', 'child-error', 'child-exit-failed'):
                        inbox.put(None)
                    else: inbox.put(value)
                except (ValueError, TypeError): inbox.put(None)

        threading.Thread(target=control_reader, daemon=True).start()
        ready = inbox.get(timeout=15)
        if not ready or ready.get('event') != 'ready' or ready.get('parentPid') != process.pid or ready.get('nodeVersion') != '24.19.0' or ready.get('uvVersion') != '1.52.1':
            raise RuntimeError('owned Node startup mismatch')
        shared.nodePid, shared.childPid = process.pid, ready['childPid']
        owned = Owned(process, ready['childPid'], nonce, shared)
        owned.pin(); located = locator.locate(owned.parent, owned.child); owned.pin()
        readers = [pipe['handle'] for pipe in located['allConnectedPipes'] if pipe['name'] == located['excludedStdoutName'] and pipe['access'] & 1]
        if len(readers) != 1:
            raise RuntimeError('owned stdout reader not unique')
        shared.nodePid, shared.childPid, shared.readerHandle = process.pid, ready['childPid'], readers[0]
        result['stage'] = 2
        module = owned.load(dll)
        if owned.remote_thread(module + export_rvas['Start']) != 1 or shared.state != 1:
            raise RuntimeError('owned observer Start failed')
        result['stage'] = 3
        owned.pin(); process.stdin.write('go\n'); process.stdin.flush(); owned.pin()
        identifiers = set(); complete = None; event_clean = True
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            owned.pin()
            while shared.tail != shared.head:
                if shared.head - shared.tail > 16:
                    raise RuntimeError('sanitized IPC sequence invalid')
                sequence = shared.tail
                event = Event.from_buffer_copy(shared.events[sequence % 16])
                if SENTINEL in bytes(event): event_clean = False
                shared.tail = sequence + 1  # x64 aligned SPSC control store; event bytes copied first.
                if event.method != 1:
                    raise RuntimeError('unknown metadata event')
                if event.kind == 1 and event.number == 101: identifier = 101
                elif event.kind == 2 and event.length == 14 and bytes(event.text)[:event.length] == b'owned-string-2': identifier = 'owned-string-2'
                else: raise RuntimeError('unexpected typed metadata id')
                if identifier in identifiers or not event_clean:
                    raise RuntimeError('duplicate or contaminated metadata')
                identifiers.add(identifier)
                owned.write_ack(located['stdinWriter']['handle'], identifier)
            try:
                message = inbox.get_nowait()
                if not message or message.get('event') != 'complete':
                    raise RuntimeError('unexpected owned control event')
                complete = message
            except queue.Empty: pass
            if complete and len(identifiers) == 2: break
            time.sleep(0.01)
        if not complete or identifiers != {101, 'owned-string-2'}:
            raise TimeoutError('owned evidence incomplete')
        result['stage'] = 4
        stop_status = owned.remote_thread(module + export_rvas['Stop'])
        stopped = stop_status == 1 and shared.state == 2
        result.update(
            owned_node_version_matches=True, uv_1_52_1=True,
            node_patch_24_19_0=True, desktop_static_patch_24_22_1=True,
            iat_started=True, iat_restored=bool(shared.iatRestored), protection_restored=bool(shared.protectionRestored),
            observer_events=len(identifiers), broker_acknowledgments=len(identifiers),
            original_bytes=complete.get('bytes', 0), original_frames=complete.get('frames', 0),
            original_bytes_equal=complete.get('byteEqual') is True, original_hash_equal=complete.get('hashEqual') is True,
            original_continued=complete.get('continued') is True, original_stderr_empty=complete.get('stderrEmpty') is True,
            observer_lines=shared.lines, observer_rejected=shared.rejects, duplicate_rejected=shared.duplicateRejects,
            observer_drops=shared.drops, immediate_reads=shared.immediate, pending_reads=shared.pending,
            gor_completions=shared.gor, gor_aborted=shared.gorAborted, zero_read_calls=shared.zeroReads,
            completed_buffers_unchanged=bool(shared.apiInvariant), coalesced_observed=bool(shared.coalesced),
            fragmented_observed=bool(shared.fragmented), sanitized_sentinel_absent=event_clean,
            no_original_stdout_read_by_broker=True, owned_remote_ops_pinned=owned.operations,
            pending_completion_proven=shared.pending > 0 and shared.gor > 0,
            demo_env_bootstrap_only=True, resident_logical_stop=stopped)
        result['coverage_unknown'] = bool(shared.drops or shared.enabled or shared.state != 2)
        result['pass'] = all((stopped, shared.iatRestored, shared.protectionRestored, shared.apiInvariant,
            complete.get('byteEqual'), complete.get('hashEqual'), complete.get('continued'), complete.get('stderrEmpty'),
            complete.get('frames') == 9, shared.lines == 9, shared.rejects == 2, shared.duplicateRejects == 2,
            shared.drops == 0, event_clean))
    except Exception as error:
        result['failure'] = True
        result['windows_error'] = int(getattr(error, 'winerror', 0) or 0)
    finally:
        if owned and module and not stopped and not owned.remote_timed_out and process.poll() is None:
            try: owned.remote_thread(module + export_rvas['Stop'])
            except Exception: pass
        if process and process.poll() is None:
            try:
                process.stdin.write('exit\n'); process.stdin.flush(); process.wait(timeout=5)
            except Exception:
                process.kill(); process.wait(timeout=5)
        if process:
            result['owned_parent_exit_zero'] = process.returncode == 0
            result['pass'] = result['pass'] and result['owned_parent_exit_zero']
        if owned: owned.shared = None
        shared = None
        if view: K.UnmapViewOfFile(view)
        if mapping: K.CloseHandle(mapping)
    encoded = json.dumps(result, separators=(',', ':')) + '\n'
    if SENTINEL.decode() in encoded: raise RuntimeError('receipt privacy invariant')
    Path(args.receipt).write_text(encoded, encoding='utf-8')
    print(encoded, end='')
    return 0 if result['pass'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node', default=str(APPROVED_NODE))
    parser.add_argument('--dll', default=str(ROOT / 'owned_node_observer.dll'))
    parser.add_argument('--receipt', required=True)
    raise SystemExit(run(parser.parse_args()))
