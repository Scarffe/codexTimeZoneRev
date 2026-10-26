"""Windows metadata-only stdin writer locator; this file has no pipe write path.

Only 32 bytes of fixed PEB/process-parameter metadata are read: a pointer and
three standard-handle values. No environment, strings, file payload, or original
stdout bytes are read. Potentially blocking file metadata queries run in bounded
disposable helper processes. Live mode requires pinned path/creation identities.
"""
import argparse
import concurrent.futures
import ctypes as C
from ctypes import wintypes as W
import json
import pathlib
import subprocess
import sys

import metadata_matrix as matrix

ROOT = pathlib.Path(__file__).resolve().parent
K, N = matrix.K, matrix.N
K.GetProcessTimes.argtypes = [W.HANDLE, C.POINTER(W.FILETIME), C.POINTER(W.FILETIME), C.POINTER(W.FILETIME), C.POINTER(W.FILETIME)]
K.GetProcessTimes.restype = W.BOOL
K.QueryFullProcessImageNameW.argtypes = [W.HANDLE, W.DWORD, W.LPWSTR, C.POINTER(W.DWORD)]
K.QueryFullProcessImageNameW.restype = W.BOOL
K.IsWow64Process2.argtypes = [W.HANDLE, C.POINTER(W.USHORT), C.POINTER(W.USHORT)]
K.IsWow64Process2.restype = W.BOOL


class HandleEntry(C.Structure):
    _fields_ = [
        ('value', W.HANDLE), ('handle_count', C.c_size_t), ('pointer_count', C.c_size_t),
        ('access', W.ULONG), ('type_index', W.ULONG), ('attributes', W.ULONG), ('reserved', W.ULONG),
    ]


def identity(pid):
    process = K.OpenProcess(0x400, False, pid)
    if not process:
        raise C.WinError(C.get_last_error())
    try:
        created, exited, kernel, user = (W.FILETIME() for _ in range(4))
        if not K.GetProcessTimes(process, C.byref(created), C.byref(exited), C.byref(kernel), C.byref(user)):
            raise C.WinError(C.get_last_error())
        path = C.create_unicode_buffer(32768)
        count = W.DWORD(len(path))
        if not K.QueryFullProcessImageNameW(process, 0, path, C.byref(count)):
            raise C.WinError(C.get_last_error())
        basic = (C.c_uint64 * 6)()
        if N.NtQueryInformationProcess(process, 0, C.byref(basic), C.sizeof(basic), None) < 0:
            raise RuntimeError('parent metadata unavailable')
        return {
            'pid': pid, 'parentPid': int(basic[5]),
            'created': (created.dwHighDateTime << 32) | created.dwLowDateTime,
            'path': path.value,
        }
    finally:
        K.CloseHandle(process)


def pinned_equal(actual, expected):
    return actual['pid'] == expected['pid'] and actual['created'] == expected['created'] and actual['path'].casefold() == expected['path'].casefold()


def require_native_64_bit(pid):
    if C.sizeof(C.c_void_p) != 8:
        raise RuntimeError('64-bit Python is required for fixed PEB metadata')
    process = K.OpenProcess(0x1000, False, pid)
    if not process:
        raise C.WinError(C.get_last_error())
    try:
        target, native = W.USHORT(), W.USHORT()
        if not K.IsWow64Process2(process, C.byref(target), C.byref(native)):
            raise C.WinError(C.get_last_error())
        if target.value != 0 or native.value not in (0x8664, 0xAA64):
            raise RuntimeError('unsupported WOW64 target; fixed PEB metadata refused')
    finally:
        K.CloseHandle(process)


def snapshot(pid):
    process = K.OpenProcess(0x400, False, pid)
    if not process:
        raise C.WinError(C.get_last_error())
    try:
        size = 65536
        for _ in range(10):
            buffer = C.create_string_buffer(size)
            needed = W.ULONG()
            status = N.NtQueryInformationProcess(process, 51, buffer, size, C.byref(needed))
            if status >= 0:
                count = C.c_size_t.from_buffer(buffer).value
                if count > 100000 or 16 + count * C.sizeof(HandleEntry) > size:
                    raise RuntimeError('invalid handle metadata snapshot')
                return [HandleEntry.from_buffer_copy(buffer, 16 + index * C.sizeof(HandleEntry)) for index in range(count)]
            size = max(size * 2, needed.value)
        raise RuntimeError('handle snapshot unavailable')
    finally:
        K.CloseHandle(process)


def bounded_query(pid, handle, method, timeout=1.5):
    try:
        completed = subprocess.run(
            [sys.executable, str(ROOT / 'metadata_matrix.py'), '--query', str(pid), str(handle), method],
            capture_output=True, text=True, timeout=timeout,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        if completed.returncode:
            return {'completed': True, 'ok': False, 'exitCode': completed.returncode}
        data = json.loads(completed.stdout)
        success = data.get('ntstatus') == '0x0' if 'ntstatus' in data else data.get('ok') is True
        return {'completed': True, 'ok': success, 'result': data}
    except subprocess.TimeoutExpired:
        return {'completed': False, 'ok': False, 'timedOut': True}


def locate(expected_parent, expected_child):
    parent_pid, child_pid = expected_parent['pid'], expected_child['pid']
    before_parent, before_child = identity(parent_pid), identity(child_pid)
    if not pinned_equal(before_parent, expected_parent) or not pinned_equal(before_child, expected_child):
        raise RuntimeError('pinned process identity mismatch')
    if before_child['parentPid'] != parent_pid:
        raise RuntimeError('child parent mismatch')

    require_native_64_bit(parent_pid)
    require_native_64_bit(child_pid)
    standards = matrix.fixed_standard_handles(child_pid)
    child_handles = {entry.value: entry for entry in snapshot(child_pid)}
    standard_entries = [child_handles.get(standards[role]) for role in ('stdin', 'stdout', 'stderr')]
    if any(entry is None for entry in standard_entries):
        raise RuntimeError('fixed standard handle missing from handle table')
    if len({entry.type_index for entry in standard_entries}) != 1:
        raise RuntimeError('standard handles do not share one object type')
    file_type = standard_entries[0].type_index
    parent_handles = [entry for entry in snapshot(parent_pid) if entry.type_index == file_type]

    # Query stdout/stderr metadata only. Never query child stdin's busy file object.
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        stdout_query, stderr_query = list(pool.map(
            lambda role: bounded_query(child_pid, standards[role], 'ObjectName'),
            ('stdout', 'stderr'),
        ))
    if not stdout_query['ok'] or not stderr_query['ok']:
        raise RuntimeError('stdout/stderr name metadata unavailable or busy')
    excluded_names = {
        stdout_query['result']['name'], stderr_query['result']['name'],
    }
    if len(excluded_names) != 2 or '' in excluded_names:
        raise RuntimeError('stdout/stderr pipe names are not distinct')

    def inspect(entry):
        local = bounded_query(parent_pid, entry.value, 'FilePipeLocal')
        if not local['ok']:
            return None
        fields = local['result']['fields']
        # Single connected NPFS instance, server end. A name shared by many pipe
        # instances cannot establish the required exact child relationship.
        if fields[2:4] != [1, 1] or fields[8:] != [3, 1]:
            return None
        users = bounded_query(parent_pid, entry.value, 'FileProcessIds')
        if not users['ok']:
            return None
        process_ids = users['result']['processIds']
        if parent_pid not in process_ids or child_pid not in process_ids:
            return None
        name = bounded_query(parent_pid, entry.value, 'ObjectName')
        if not name['ok'] or not name['result']['name']:
            return None
        return {
            'handle': entry.value, 'access': entry.access,
            'name': name['result']['name'], 'processIds': process_ids,
            'localFields': fields,
        }

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        candidates = [value for value in pool.map(inspect, parent_handles) if value is not None]
    names = {value['name'] for value in candidates}
    if len(names) != 3 or not excluded_names.issubset(names):
        raise RuntimeError(f'exact standard-pipe set not established; connected names={len(names)}')
    remaining_names = names - excluded_names
    stdin_candidates = [value for value in candidates if value['name'] in remaining_names and value['access'] & 2]
    if len(remaining_names) != 1 or len(stdin_candidates) != 1:
        raise RuntimeError(f'stdin write handle is not unique; remaining names={len(remaining_names)}, writable handles={len(stdin_candidates)}')

    after_parent, after_child = identity(parent_pid), identity(child_pid)
    if before_parent != after_parent or before_child != after_child:
        raise RuntimeError('process identity changed during metadata association')
    return {
        'status': 'LOCATED_BY_METADATA_ONLY',
        'parent': before_parent, 'child': before_child,
        'fixedProcessMemoryBytesRead': standards['bytesRead'],
        'standardHandles': {role: standards[role] for role in ('stdin', 'stdout', 'stderr')},
        'childStdinNameQueried': False,
        'parentConnectedPipeCount': len(candidates), 'parentConnectedNameCount': len(names),
        'excludedStdoutName': stdout_query['result']['name'],
        'excludedStderrName': stderr_query['result']['name'],
        'stdinWriter': stdin_candidates[0],
        'allConnectedPipes': candidates,
        'parentAndChildIdentityUnchanged': True,
        'pipePayloadBytesRead': 0, 'pipeWrites': 0,
        'associationRule': 'single-instance pipes used by exact child minus exact stdout/stderr names; unique writable remainder',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=['identity-only', 'locate'], required=True)
    parser.add_argument('--parent-pid', type=int, required=True)
    parser.add_argument('--child-pid', type=int, required=True)
    parser.add_argument('--parent-created', type=int)
    parser.add_argument('--child-created', type=int)
    parser.add_argument('--parent-path')
    parser.add_argument('--child-path')
    parser.add_argument('--receipt')
    args = parser.parse_args()
    if args.mode == 'identity-only':
        result = {'parent': identity(args.parent_pid), 'child': identity(args.child_pid)}
    else:
        for key in ('parent_created', 'child_created', 'parent_path', 'child_path'):
            if getattr(args, key) is None:
                parser.error(f'locate requires --{key.replace("_", "-")}')
        result = locate(
            {'pid': args.parent_pid, 'created': args.parent_created, 'path': args.parent_path},
            {'pid': args.child_pid, 'created': args.child_created, 'path': args.child_path},
        )
    if args.receipt:
        pathlib.Path(args.receipt).write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
