"""Exercise the compiled probe against its own surrogate, never real Codex."""
import datetime
import json
import pathlib
import queue
import shutil
import subprocess
import sys
import threading

ROOT = pathlib.Path(__file__).resolve().parent

def main():
    executable = pathlib.Path(sys.argv[1]).resolve(strict=True)
    fixture = subprocess.Popen(
        [shutil.which('node'), str(ROOT / 'fake_desktop_native.cjs'), str(executable)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding='utf-8', creationflags=subprocess.CREATE_NO_WINDOW,
    )
    inbox = queue.Queue()
    received = []
    context = {'status': 'STARTED', 'realCodexProcessAccess': False, 'modelRequests': 0}

    def read_fixture():
        for line in fixture.stdout:
            try:
                inbox.put(json.loads(line))
            except Exception as error:
                inbox.put({'event': 'fixture-invalid-json', 'error': str(error)})

    threading.Thread(target=read_fixture, daemon=True).start()

    def receive():
        event = inbox.get(timeout=10)
        received.append(event)
        return event

    def send(kind, sequence):
        fixture.stdin.write(json.dumps({'type': kind, 'seq': sequence}) + '\n')
        fixture.stdin.flush()

    def probe(*arguments):
        completed = subprocess.run(
            [str(executable), *map(str, arguments)], capture_output=True,
            text=True, encoding='utf-8', timeout=40,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        if completed.returncode:
            raise RuntimeError(completed.stderr.strip() or f'probe failed {completed.returncode}')
        return json.loads(completed.stdout)

    try:
        context['stage'] = 'await-parent-ready'
        ready = receive()
        context['ready'] = ready
        assert ready['event'] == 'fixture-ready', ready

        context['stage'] = 'await-child-ready'
        child_ready = receive()
        context['childReady'] = child_ready
        assert child_ready['message']['method'] == 'fixture/ready', child_ready

        identity_args = ['--parent-pid', ready['parentPid'], '--child-pid', ready['childPid']]
        context['stage'] = 'identity'
        before_identity = probe('--identity-only', *identity_args)
        context['identity'] = before_identity
        pinned_args = list(identity_args)
        for role in ('parent', 'child'):
            pinned_args.extend([
                f'--{role}-created', before_identity[role]['created'],
                f'--{role}-path', before_identity[role]['path'],
            ])

        context['stage'] = 'original-reader-baseline'
        send('normal', 0)
        baseline = receive()
        assert baseline['message']['method'] == 'fixture/received', baseline

        context['stage'] = 'enum-only'
        enumeration = probe('--enum-only', *pinned_args)
        context['enumeration'] = enumeration
        stdin_metadata = child_ready['message']['params']
        matches = [item for item in enumeration['pipes'] if item['name'] == stdin_metadata['stdinName']]
        assert len(matches) == 1, {'candidateCount': len(enumeration['pipes']), 'matches': len(matches)}

        context['stage'] = 'fixture-write'
        write_receipt = probe(
            '--fixture-write', *pinned_args,
            '--fixture-stdin-name', stdin_metadata['stdinName'],
            '--fixture-stdin-handle', stdin_metadata['stdinHandle'],
        )
        context['writeReceipt'] = write_receipt
        assert write_receipt['writePerformed'] is True, write_receipt

        context['stage'] = 'original-reader-observe-update'
        notification = receive()
        response = receive()
        assert notification['message']['method'] == 'account/updated', notification
        assert response['message']['method'] == 'fixture/received', response
        assert response['message']['params']['authRevision'] == 1, response

        context['stage'] = 'original-reader-post-update'
        for sequence in range(1, 101):
            send('normal', sequence)
        for _ in range(100):
            event = receive()
            assert event['message']['method'] == 'fixture/received', event
            assert event['message']['params']['authRevision'] == 1, event

        context['stage'] = 'identity-unchanged'
        after_identity = probe('--identity-only', *identity_args)
        assert before_identity == after_identity, 'fixture identity changed'
        assert fixture.poll() is None, 'fixture parent exited'
        assert all(
            event['parentPid'] == ready['parentPid']
            and event['childPid'] == ready['childPid']
            and event['startedAt'] == ready['startedAt']
            for event in received if event['event'] == 'child-message'
        ), 'fixture message identity changed'

        result = {
            'status': 'PASS_ISOLATED_CPP_FIXTURE',
            'parentAndChildIdentityUnchanged': True,
            'originalReaderReceivedAccountUpdated': True,
            'originalReaderReceivedPostUpdateReplies': 101,
            'stdinCandidateUnique': True,
            'pipeClientPidIsCreatorNotInheritedChild': matches[0]['clientCreatorPid'] == ready['parentPid'],
            'lowEventBitUsed': True,
            'writePayloadLogged': False,
            'realCodexProcessAccess': False,
            'realDesktopHotSwitch': 'NOT_RUN',
            'externalTokenRefresh': 'NOT_IMPLEMENTED',
            'modelRequests': 0,
        }
        (ROOT / 'cpp-fixture-result.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        print(json.dumps(result, indent=2))
    except Exception as error:
        context.update(status='FAILED_ISOLATED_CPP_FIXTURE', error=str(error), eventsReceived=len(received))
        receipt = json.dumps(context, indent=2) + '\n'
        (ROOT / 'cpp-fixture-failure.json').write_text(receipt, encoding='utf-8')
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        (ROOT / f'cpp-fixture-failure-{stamp}.json').write_text(receipt, encoding='utf-8')
        raise
    finally:
        if fixture.poll() is None:
            send('exit', 999)
            try:
                fixture.wait(timeout=5)
            except subprocess.TimeoutExpired:
                fixture.kill()
                fixture.wait()

if __name__ == '__main__':
    main()
