"""Read-only FFI acceptance. Keeps fixture files for optional isolated UI smoke."""
import argparse, ctypes, json, os, hashlib
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--library',required=True);p.add_argument('--fixtures',required=True);p.add_argument('--live-session');a=p.parse_args()
lib=ctypes.CDLL(str(Path(a.library).resolve()))
lib.launcher_call.argtypes=[ctypes.c_char_p];lib.launcher_call.restype=ctypes.c_void_p
lib.launcher_free.argtypes=[ctypes.c_void_p]
def call(payload):
    ptr=lib.launcher_call(json.dumps({'version':1,'command':'session_metrics','payload':payload}).encode())
    try:return json.loads(ctypes.string_at(ptr))
    finally:lib.launcher_free(ptr)
def event(kind,turn,**kw):
    return {'type':'token_usage_record' if kind=='token_usage_record' else 'event_msg','payload':{'type':kind,'turn_id':turn,**kw}}
base=Path(a.fixtures).resolve();sessions=base/'sessions'/'2026'/'10'/'21';sessions.mkdir(parents=True,exist_ok=True)
main=sessions/'rollout-2026-10-21-main.jsonl';child=sessions/'rollout-2026-10-21-subagent.jsonl'
meta={'type':'session_meta','payload':{'id':'fixture-main','source':'vscode','cwd':'fixture','timestamp':'2026-10-21T00:00:00Z'}}
records=[meta,{'type':'response_item','payload':{'content':'PRIVATE_PROMPT_DO_NOT_EXPORT'}},event('task_started','older'),event('task_started','a'),event('token_usage_record','a',turn_token_usage={'output_tokens':20,'reasoning_output_tokens':5}),event('token_usage_record','a',turn_token_usage={'output_tokens':20,'reasoning_output_tokens':5}),event('task_complete','a',duration_ms=2000,time_to_first_token_ms=300),event('token_count','a',info={'total_token_usage':{'output_tokens':999999}})]
main.write_text(''.join(json.dumps(x)+'\n' for x in records),encoding='utf-8')
child.write_text(json.dumps({'type':'session_meta','payload':{'id':'sub','source':{'subagent':{'guardian':{}}}}})+'\n',encoding='utf-8')
old=os.environ.get('CODEX_HOME');os.environ['CODEX_HOME']=str(base)
try:
    listed=call({'action':'list'});assert listed['ok'];assert [s['id'] for s in listed['data']['sessions']]==['fixture-main']
    before=hashlib.sha256(main.read_bytes()).hexdigest();v=call({'path':str(main)})['data']
    assert v['last']['tokensPerSecond']==10 and not v['active'];assert v['last']['reasoningTokens']==5
    assert 'PRIVATE_PROMPT' not in json.dumps(v);assert before==hashlib.sha256(main.read_bytes()).hexdigest()
    assert not call({'path':str(child)})['ok'];assert not call({'path':__file__})['ok']
    # A later record for an old turn must not alter the latest completed turn.
    with main.open('a',encoding='utf-8') as f:f.write(json.dumps(event('token_usage_record','older',turn_token_usage={'output_tokens':999}))+'\n')
    assert call({'path':str(main)})['data']['last']['tokensPerSecond']==10
    print('PASS: main-session filtering, snapshots, turn association, private-content exclusion, read-only hash, path restriction')
finally:
    if old is None:os.environ.pop('CODEX_HOME',None)
    else:os.environ['CODEX_HOME']=old
if a.live_session:
    v=call({'path':str(Path(a.live_session).resolve())});assert v['ok'],v
    for _ in range(100):
        if not v['data']['catchingUp']:break
        v=call({'path':str(Path(a.live_session).resolve())})
    assert not v['data']['catchingUp'];assert v['data']['last']['tokensPerSecond'] is not None
    print('PASS: real session numeric collection',json.dumps(v['data'],ensure_ascii=True))
print('FIXTURE_CODEX_HOME='+str(base))
print('FIXTURE_SESSION='+str(main))
