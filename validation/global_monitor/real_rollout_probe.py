"""Bounded public-ABI local-log observation; persists aggregate evidence only."""
import argparse
import json
import pathlib
import queue
import subprocess
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', required=True)
    parser.add_argument('--library', required=True)
    parser.add_argument('--receipt', required=True)
    parser.add_argument('--passes', type=int, default=8)
    args = parser.parse_args()
    receipt = pathlib.Path(args.receipt)
    if receipt.exists():
        raise RuntimeError('preserve_existing_receipt')
    process = subprocess.Popen(
        [str(pathlib.Path(args.host).resolve(strict=True)),
         str(pathlib.Path(args.library).resolve(strict=True))],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, encoding='utf-8',
        creationflags=subprocess.CREATE_NO_WINDOW,
    )
    replies = queue.Queue()
    def read():
        for line in process.stdout:
            replies.put(json.loads(line))
    threading.Thread(target=read, daemon=True).start()
    def call(payload):
        process.stdin.write(json.dumps({'version': 1, 'command': 'global_monitor', 'payload': payload}) + '\n')
        process.stdin.flush()
        value = replies.get(timeout=60)
        if value.get('ok') is not True:
            raise RuntimeError(value.get('error', 'ffi_failed'))
        return value['data']
    started = time.monotonic()
    try:
        capability = call({'action': 'capabilities'})
        scans = []
        for _ in range(min(max(args.passes, 1), 64)):
            value = call({'action': 'scan', 'generation': 1})
            scans.append({'revision': value['revision'], 'phase': value['phase'],
                          'coverage': value['coverage'], 'bytesRead': value.get('bytesRead'),
                          'visitedFiles': value.get('visitedFiles')})
            if value['phase'] not in ('scanning',):
                break
        snapshot = call({'action': 'query', 'limit': 1})
        call({'action': 'shutdown'})
        result = {
            'status': 'PASS_READONLY_BOUNDED_PUBLIC_FFI',
            'completion': 'PARTIAL_BUDGET' if snapshot['phase'] == 'scanning' else snapshot['phase'],
            'elapsedSeconds': round(time.monotonic() - started, 2),
            'capability': capability, 'scans': scans,
            'revision': snapshot['revision'], 'coverage': snapshot['coverage'],
            'logicalSessions': snapshot['filteredCount'],
            'projectGroupCount': len(snapshot['projects']),
            'modelGroupCount': len(snapshot['models']),
            'dailyBucketCount': len(snapshot['daily']),
            'totals': snapshot['totals'], 'warnings': snapshot['warnings'],
            'conversationContentPersisted': False,
            'sessionIdentifiersPersisted': False,
            'credentialFilesRead': False,
            'modelRequests': 0,
            'realDesktopAttachment': 'NOT_RUN',
        }
        receipt.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({k: result[k] for k in ('status', 'completion', 'elapsedSeconds', 'logicalSessions', 'projectGroupCount', 'modelGroupCount', 'coverage')}, indent=2))
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            # This is only the exact host we just spawned, never Codex.
            process.kill()
            process.wait()


if __name__ == '__main__':
    main()
