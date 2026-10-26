"""Owned native observer acceptance: 256KiB unrelated result, then typed refreshes."""
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
FROZEN_V3 = ROOT.parent / 'hot-spike' / 'attachment-v2' / 'node-observer-v3'
sys.path.insert(0, str(ROOT.parent / 'hot_runtime' / 'attachment-v2'))
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


class LegacyStartConfig(C.Structure):
    _fields_ = [(name, W.DWORD) for name in ('magic', 'version', 'bytes', 'nodePid', 'mappingBytes', 'mappingVersion')] + [
        ('generation', C.c_uint64), ('mappingName', W.WCHAR * 200)]


class ModuleProof(C.Structure):
    _fields_ = [('imageSize', C.c_uint64), ('imageTimestamp', W.DWORD), ('reserved', W.DWORD), ('sha256', C.c_ubyte * 32)]


class HandleProof(C.Structure):
    _fields_ = [('exactStdoutReader', C.c_uint64), ('ownerCreationFileTime', C.c_uint64),
        ('childCreationFileTime', C.c_uint64), ('ownerPid', W.DWORD), ('childPid', W.DWORD)]


class StartConfig(C.Structure):
    _fields_ = [('magic', W.DWORD), ('version', W.DWORD), ('bytes', W.DWORD), ('role', W.DWORD),
        ('ownerGeneration', C.c_uint64), ('expectedModule', ModuleProof), ('establishedStdio', HandleProof),
        ('mappingVersion', W.DWORD), ('mappingBytes', W.DWORD), ('mappingName', W.WCHAR * 200)]


class Overlapped(C.Structure):
    _fields_ = [('Internal', SIZE), ('InternalHigh', SIZE), ('Offset', W.DWORD),
                ('OffsetHigh', W.DWORD), ('hEvent', W.HANDLE)]


class ModuleEntry(C.Structure):
    _fields_ = [('dwSize', W.DWORD), ('th32ModuleID', W.DWORD), ('th32ProcessID', W.DWORD),
                ('GlblcntUsage', W.DWORD), ('ProccntUsage', W.DWORD), ('modBaseAddr', PTR),
                ('modBaseSize', W.DWORD), ('hModule', W.HMODULE),
                ('szModule', W.WCHAR * 256), ('szExePath', W.WCHAR * 260)]


assert C.sizeof(PTR) == 8 and C.sizeof(Event) == 88 and Shared.events.offset == 144 and C.sizeof(Shared) == 1552
assert LegacyStartConfig.generation.offset == 24 and LegacyStartConfig.mappingName.offset == 32 and C.sizeof(LegacyStartConfig) == 432
assert C.sizeof(ModuleProof) == 48 and C.sizeof(HandleProof) == 32 and StartConfig.expectedModule.offset == 24 and C.sizeof(StartConfig) == 512
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
    def __init__(self, process, child_pid):
        self.process, self.generation, self.shared = process, None, None
        self.remote_timed_out = False
        self.parent = locator.identity(process.pid)
        self.child = locator.identity(child_pid)
        if self.parent['path'].casefold() != str(APPROVED_NODE).casefold() or self.child['path'].casefold() != str(APPROVED_NODE).casefold() or self.child['parentPid'] != process.pid:
            raise RuntimeError('owned process provenance mismatch')
        self.handle = int(process._handle)  # Retained CreateProcess capability, not arbitrary OpenProcess.
        self.operations = 0

    def pin(self):
        generation_matches = (self.shared is None and self.generation is None) or (self.shared is not None and bytes(self.shared.nonce) == self.generation.encode() and self.shared.nodePid == self.parent['pid'] and self.shared.childPid == self.child['pid'] and self.shared.brokerPid == os.getpid())
        if not generation_matches or self.process.poll() is not None or not locator.pinned_equal(locator.identity(self.parent['pid']), self.parent) or not locator.pinned_equal(locator.identity(self.child['pid']), self.child):
            raise RuntimeError('owned identity changed')

    def operation(self, function, *args):
        if self.shared is None:
            raise RuntimeError('explicit attachment generation not initialized')
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

    def start(self, address, map_name, legacy=False):
        config = LegacyStartConfig() if legacy else StartConfig()
        config.magic, config.version, config.bytes = 0x434f4e46, 1, C.sizeof(config)
        config.mappingBytes, config.mappingVersion, config.mappingName = C.sizeof(Shared), 1, map_name
        if legacy:
            config.nodePid, config.generation = self.process.pid, int(self.generation, 16)
        else:
            config.role, config.ownerGeneration = 1, int(self.generation, 16)  # Finite NodeFixture role only.
            node_disk = APPROVED_NODE.read_bytes()
            pe = struct.unpack_from('<I', node_disk, 0x3c)[0]
            config.expectedModule.imageSize = struct.unpack_from('<I', node_disk, pe + 24 + 56)[0]
            config.expectedModule.imageTimestamp = struct.unpack_from('<I', node_disk, pe + 8)[0]
            config.expectedModule.sha256[:] = bytes.fromhex(NODE_SHA256)
            config.establishedStdio.exactStdoutReader = self.shared.readerHandle
            config.establishedStdio.ownerCreationFileTime = self.parent['created']
            config.establishedStdio.childCreationFileTime = self.child['created']
            config.establishedStdio.ownerPid, config.establishedStdio.childPid = self.parent['pid'], self.child['pid']
        allocation = required(self.operation(K.VirtualAllocEx, self.handle, None, C.sizeof(config), 0x3000, 4))
        try:
            written = SIZE()
            required(self.operation(K.WriteProcessMemory, self.handle, allocation, C.byref(config), C.sizeof(config), C.byref(written)))
            if written.value != C.sizeof(config):
                raise RuntimeError('incomplete explicit bootstrap copy')
            return self.remote_thread(address, allocation)
        finally:
            if not self.remote_timed_out:
                required(self.operation(K.VirtualFreeEx, self.handle, allocation, 0, 0x8000))

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
    initial_progress = None; identifiers = set()
    retired_mappings = []
    try:
        if args.legacy_v3 and args.rearm_dll: raise RuntimeError('incompatible fixed DLL modes')
        expected_dll = (FROZEN_V3 / 'owned_node_observer.dll') if args.legacy_v3 else (ROOT / ('rearm_node_observer.dll' if args.rearm_dll else 'owned_node_observer.dll'))
        node, dll = Path(args.node).resolve(strict=True), Path(args.dll or expected_dll).resolve(strict=True)
        scoped_fixed_artifact = bool(args.dll and not args.legacy_v3 and dll.name.casefold() == 'scoped_rearm_node_observer.dll')
        if node != APPROVED_NODE.resolve(strict=True) or hashlib.sha256(node.read_bytes()).hexdigest() != NODE_SHA256 or (not scoped_fixed_artifact and dll != expected_dll.resolve(strict=True)):
            raise RuntimeError('unapproved owned artifact path or build')
        export_rvas = exports(dll)
        work = ROOT / ('owned-temp-' + secrets.token_hex(8)); work.mkdir()
        system = os.environ.get('SystemRoot', r'C:\Windows')
        environment = {'SystemRoot': system, 'WINDIR': system, 'TEMP': str(work), 'TMP': str(work)}
        result['stage'] = 1
        process = subprocess.Popen([str(node), str(ROOT / 'owned_node_parent.cjs')], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8', env=environment,
            cwd=str(ROOT), creationflags=subprocess.CREATE_NO_WINDOW)
        inbox = queue.Queue()

        def control_reader():
            for line in process.stdout:
                try:
                    value = json.loads(line)
                    if value.get('event') not in ('spawned', 'ready', 'initial-drained', 'complete', 'extra-bytes', 'child-error', 'child-exit-failed'):
                        inbox.put(None)
                    else: inbox.put(value)
                except (ValueError, TypeError): inbox.put(None)

        threading.Thread(target=control_reader, daemon=True).start()
        spawned = inbox.get(timeout=15)
        if not spawned or spawned.get('event') != 'spawned' or spawned.get('parentPid') != process.pid or spawned.get('nodeVersion') != '24.19.0' or spawned.get('uvVersion') != '1.52.1':
            raise RuntimeError('owned Node startup mismatch')
        owned = Owned(process, spawned['childPid'])
        # Record/pin PID, creation time and path before normal RPCs and before attachment exists.
        owned.pin(); process.stdin.write('warmup\n'); process.stdin.flush(); owned.pin()
        ready = inbox.get(timeout=15)
        if not ready or ready.get('event') != 'ready' or ready.get('parentPid') != owned.parent['pid'] or ready.get('childPid') != owned.child['pid'] or ready.get('baselineRequests') != 3 or ready.get('baselineResponses') != 3 or ready.get('baselineByteEqual') is not True:
            raise RuntimeError('pre-attachment normal RPC baseline failed')
        owned.pin()
        if any(path == str(dll).casefold() for _, path, _ in owned.modules()):
            raise RuntimeError('observer unexpectedly preloaded')
        # Only now create a fresh attachment generation and explicit Start configuration.
        generation = secrets.randbits(64) or 1
        generation_text = f'{generation:016x}'
        map_name = 'Local\\OwnedNodeObserverV3-' + str(os.getpid()) + '-' + generation_text
        mapping = required(K.CreateFileMappingW(C.c_void_p(-1), None, 4, 0, C.sizeof(Shared), map_name))
        if C.get_last_error() == 183: raise RuntimeError('owned mapping unexpectedly existed')
        view = required(K.MapViewOfFile(mapping, 0xf001f, 0, 0, C.sizeof(Shared)))
        C.memset(view, 0, C.sizeof(Shared)); shared = Shared.from_address(view)
        shared.magic, shared.version, shared.bytes, shared.brokerPid = 0x4f4e4f42, 1, C.sizeof(Shared), os.getpid()
        shared.nodePid, shared.childPid, shared.nonce = owned.parent['pid'], owned.child['pid'], generation_text.encode()
        owned.shared, owned.generation = shared, generation_text
        owned.pin(); located = locator.locate(owned.parent, owned.child); owned.pin()
        readers = [pipe['handle'] for pipe in located['allConnectedPipes'] if pipe['name'] == located['excludedStdoutName'] and pipe['access'] & 1]
        if len(readers) != 1:
            raise RuntimeError('owned stdout reader not unique')
        shared.nodePid, shared.childPid, shared.readerHandle = process.pid, ready['childPid'], readers[0]
        result['stage'] = 2
        module = owned.load(dll)
        if owned.start(module + export_rvas['Start'], map_name, args.legacy_v3) != 1 or shared.state != 1:
            raise RuntimeError('owned observer Start failed')
        result['stage'] = 3
        if args.rearm_before_stream:
            first_stop = owned.remote_thread(module + export_rvas['Stop'])
            first_restored = first_stop == 2 and shared.state == 2 and bool(shared.iatRestored) and bool(shared.protectionRestored)
            result.update(rearm_first_stop_success=first_restored, rearm_first_stop_status=first_stop)
            if not first_restored: raise RuntimeError('first logical Stop did not restore IAT')
            stopped = True
            owned.pin()
            next_generation = secrets.randbits(64) or 1
            if next_generation == int(owned.generation, 16): next_generation = next_generation % ((1 << 64) - 1) + 1
            next_text = f'{next_generation:016x}'
            next_name = 'Local\\OwnedObserverRearm-' + str(os.getpid()) + '-' + next_text
            next_mapping = required(K.CreateFileMappingW(C.c_void_p(-1), None, 4, 0, C.sizeof(Shared), next_name))
            if C.get_last_error() == 183: K.CloseHandle(next_mapping); raise RuntimeError('rearm mapping existed')
            next_view = K.MapViewOfFile(next_mapping, 0xf001f, 0, 0, C.sizeof(Shared))
            if not next_view: K.CloseHandle(next_mapping); raise C.WinError(C.get_last_error())
            next_shared = Shared.from_address(next_view); C.memset(next_view, 0, C.sizeof(Shared))
            next_shared.magic, next_shared.version, next_shared.bytes, next_shared.brokerPid = 0x4f4e4f42, 1, C.sizeof(Shared), os.getpid()
            next_shared.nodePid, next_shared.childPid = owned.parent['pid'], owned.child['pid']
            next_shared.readerHandle, next_shared.nonce = shared.readerHandle, next_text.encode()
            retired_mappings.append((mapping, view))  # Old view stays resident until owned process exits.
            shared, mapping, view = next_shared, next_mapping, next_view
            owned.shared, owned.generation = shared, next_text
            owned.pin()
            second_start = owned.start(module + export_rvas['Start'], next_name)
            result.update(rearm_second_start_status=second_start,
                rearm_red_invalid_config10=second_start == 10 and first_restored,
                rearm_same_owned_pid_and_creation=True)
            if second_start != 1 or shared.state != 1:
                raise RuntimeError('second Start after logical Stop failed')
            stopped = False
            result['rearm_new_generation_started'] = True
        owned.pin(); process.stdin.write('go\n'); process.stdin.flush(); owned.pin()
        complete = None; event_clean = True
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
                if message and message.get('event') == 'initial-drained':
                    initial_progress = message
                elif not message or message.get('event') != 'complete':
                    raise RuntimeError('unexpected owned control event')
                else:
                    complete = message
            except queue.Empty: pass
            if complete and len(identifiers) == 2: break
            time.sleep(0.01)
        if not complete or identifiers != {101, 'owned-string-2'}:
            raise TimeoutError('owned evidence incomplete')
        result['stage'] = 4
        stop_status = owned.remote_thread(module + export_rvas['Stop'])
        result['final_stop_status'] = stop_status
        stopped = stop_status == (1 if args.legacy_v3 else 2) and shared.state == 2
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
            baseline_requests=ready['baselineRequests'], baseline_responses=ready['baselineResponses'],
            baseline_bytes_equal=ready['baselineByteEqual'], baseline_before_injection=True,
            owned_pid_and_creation_unchanged=True, no_observer_preload=True,
            no_observer_environment_bootstrap=True, explicit_start_config=True,
            explicit_config_bytes=C.sizeof(LegacyStartConfig) if args.legacy_v3 else C.sizeof(StartConfig), resident_logical_stop=stopped,
            finite_node_role=not args.legacy_v3, large_frame_recovery=bool(complete and len(identifiers) == 2 and shared.drops == 0),
            initial_original_bytes=initial_progress.get('bytes', 0) if initial_progress else 0,
            initial_original_frames=initial_progress.get('frames', 0) if initial_progress else 0,
            unrelated_result_bytes=initial_progress.get('largeResultBytes', 0) if initial_progress else 0)
        result['coverage_unknown'] = bool(shared.drops or shared.enabled or shared.state != 2)
        result['pass'] = all((stopped, shared.iatRestored, shared.protectionRestored, shared.apiInvariant,
            complete.get('byteEqual'), complete.get('hashEqual'), complete.get('continued'), complete.get('stderrEmpty'),
            complete.get('frames') == 10, shared.lines == 10, shared.rejects == 2, shared.duplicateRejects == 2,
            initial_progress and initial_progress.get('byteEqual') and initial_progress.get('hashEqual') and initial_progress.get('largeResultBytes') == 262144,
            shared.drops == 0, event_clean))
    except Exception as error:
        result['failure'] = True
        result['windows_error'] = int(getattr(error, 'winerror', 0) or 0)
        if shared is not None:
            result.update(observer_drops=shared.drops, observer_lines=shared.lines,
                observer_disabled=shared.enabled == 0, immediate_reads=shared.immediate,
                pending_reads=shared.pending, gor_completions=shared.gor,
                observer_events=len(identifiers), broker_acknowledgments=len(identifiers))
        if initial_progress:
            result.update(initial_original_bytes=initial_progress.get('bytes', 0),
                initial_original_frames=initial_progress.get('frames', 0),
                initial_original_bytes_equal=initial_progress.get('byteEqual') is True,
                initial_original_hash_equal=initial_progress.get('hashEqual') is True,
                unrelated_result_bytes=initial_progress.get('largeResultBytes', 0))
        result['red_old_dll_capacity_failure_observed'] = bool(result['stage'] == 3 and shared is not None and shared.drops > 0 and shared.enabled == 0 and initial_progress and initial_progress.get('largeResultBytes') == 262144 and initial_progress.get('byteEqual') is True and initial_progress.get('hashEqual') is True and not identifiers)
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
        for retired_mapping, retired_view in retired_mappings:
            K.UnmapViewOfFile(retired_view); K.CloseHandle(retired_mapping)
    encoded = json.dumps(result, separators=(',', ':')) + '\n'
    if SENTINEL.decode() in encoded: raise RuntimeError('receipt privacy invariant')
    Path(args.receipt).write_text(encoded, encoding='utf-8')
    print(encoded, end='')
    return 0 if result['pass'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node', default=str(APPROVED_NODE))
    parser.add_argument('--dll')
    parser.add_argument('--legacy-v3', action='store_true', help='Reproduce RED with the exact frozen v3 DLL')
    parser.add_argument('--rearm-before-stream', action='store_true', help='Start/Stop then new generation Start in the same owned PID before GO')
    parser.add_argument('--rearm-dll', action='store_true', help='Use only the fixed new rearm_node_observer.dll artifact')
    parser.add_argument('--receipt', required=True)
    raise SystemExit(run(parser.parse_args()))
