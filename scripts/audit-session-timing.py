"""Read-only H2 audit. Exports numeric aggregates/schema names, never item content."""
import argparse, collections, ctypes, hashlib, json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--session', required=True)
p.add_argument('--library')
p.add_argument('--output', required=True)
a = p.parse_args()
path = Path(a.session).resolve()
snapshot = path.read_bytes()
turns = collections.defaultdict(lambda: {'items': {}, 'responses': {}, 'done': {}, 'last': {}})
counts = collections.Counter()
shapes = collections.defaultdict(set)
item_ids, response_ids = set(), set()
completed = []
delta_count = 0
for raw in snapshot.splitlines(keepends=True):
    if not raw.endswith(b'\n'):
        continue
    try:
        v = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        continue
    q = v.get('payload', {})
    if not isinstance(q, dict):
        continue
    kind = 'token_usage_record' if v.get('type') == 'token_usage_record' else q.get('type', '') if v.get('type') == 'event_msg' else ''
    if not kind:
        continue
    counts[kind] += 1
    if 'delta' in kind.lower():
        delta_count += 1
    if kind in ('task_complete', 'item_completed', 'token_usage_record'):
        shapes[kind].update(q.keys())
    tid = q.get('turn_id')
    if not tid:
        continue
    t = turns[tid]
    if kind == 'task_complete':
        t['done'] = {k: q.get(k) for k in ('duration_ms', 'started_at', 'completed_at', 'time_to_first_token_ms')}
        completed.append(tid)
    elif kind == 'token_usage_record':
        rid = q.get('response_id')
        if rid:
            response_ids.add(rid)
            t['responses'][rid] = q.get('usage', {})
        t['last'] = q.get('turn_token_usage', {})
    elif kind == 'item_completed':
        it = q.get('item', {})
        item_id = it.get('id')
        if item_id:
            item_ids.add(item_id)
            if it.get('type') != 'UserMessage':
                t['items'][item_id] = (it.get('type'), q.get('started_at_ms'), q.get('completed_at_ms'))


def union(values):
    spans = []
    for start, end in sorted(values):
        if spans and start <= spans[-1][1]:
            spans[-1][1] = max(end, spans[-1][1])
        else:
            spans.append([start, end])
    return sum(end - start for start, end in spans)


def analyze(t):
    d = t['done']
    duration, start, end = (d.get(k) for k in ('duration_ms', 'started_at', 'completed_at'))
    bounds_valid = all(type(x) is int and x >= 0 for x in (duration, start, end)) and end >= start and abs((end-start)*1000-duration) <= 999
    groups = collections.defaultdict(list)
    invalid = zero = outside = 0
    for kind, x, y in t['items'].values():
        if type(x) is not int or type(y) is not int or x < 0 or y < x:
            invalid += 1
        elif x == y:
            zero += 1
        elif bounds_valid and (x < start*1000 or y > (end+1)*1000):
            outside += 1
        else:
            category = 'messageMs' if kind == 'AgentMessage' else 'reasoningMs' if kind == 'Reasoning' else 'toolMs' if kind in ('CommandExecution','McpToolCall','FileChange','DynamicToolCall','CollabToolCall') else 'otherMs'
            groups[category].append((x, y))
    intervals = [i for g in groups.values() for i in g]
    observed = union(intervals) if intervals else None
    v = {k: union(groups[k]) if groups[k] else None for k in ('messageMs','reasoningMs','toolMs','otherMs')}
    outputs = [r.get('output_tokens') for r in t['responses'].values()]
    total = sum(outputs) if outputs and all(type(x) is int for x in outputs) else None
    valid = bounds_valid and observed is not None and observed <= duration
    v.update(responseCount=len(outputs), responseOutputTokens=total, usageMatchesTurn=total == t['last'].get('output_tokens') if total is not None else None,
             observedMs=observed, overlapMs=sum(x or 0 for x in v.values())-observed if observed is not None else None,
             unclassifiedMs=duration-observed if valid else None, boundsValid=bounds_valid, coverageValid=valid,
             validItems=len(intervals), invalidItems=invalid, zeroItems=zero, outOfBoundsItems=outside)
    return v

samples = [dict(turnId=tid, durationMs=turns[tid]['done'].get('duration_ms'), analysis=analyze(turns[tid])) for tid in completed[-5:]]
verified = None
if a.library:
    lib = ctypes.CDLL(str(Path(a.library).resolve()))
    lib.launcher_call.argtypes = [ctypes.c_char_p]
    lib.launcher_call.restype = ctypes.c_void_p
    lib.launcher_free.argtypes = [ctypes.c_void_p]
    for _ in range(100):
        ptr = lib.launcher_call(json.dumps({'version':1,'command':'session_metrics','payload':{'path':str(path)}}).encode())
        try:
            result = json.loads(ctypes.string_at(ptr))
        finally:
            lib.launcher_free(ptr)
        assert result['ok'], result
        if not result['data']['catchingUp']:
            break
    assert not result['data']['catchingUp'], 'history catch-up incomplete'
    last = result['data']['last']
    assert last['turnId'] in turns, 'live file completed another turn after snapshot; retry audit'
    expected = analyze(turns[last['turnId']])
    for key, value in expected.items():
        assert last['analysis'][key] == value, (key, last['analysis'][key], value)
    assert last['analysis']['generationTokensPerSecond'] is None
    verified = {'turnId':last['turnId'], 'independentFieldsMatched':len(expected)}
with path.open('rb') as f:
    unchanged = f.read(len(snapshot)) == snapshot
assert unchanged, 'source prefix changed during read-only audit'
report = dict(snapshotBytes=len(snapshot), snapshotSha256=hashlib.sha256(snapshot).hexdigest(), sourcePrefixUnchanged=unchanged,
              eventCounts=counts, fieldNames={k:sorted(v) for k,v in shapes.items()}, persistedDeltaCount=delta_count,
              itemResponseIdMatches=len(item_ids & response_ids), timingMeaning='client_log_item_intervals_not_decoder_time',
              responseItemAssociation='not_established', recentCompleted=samples, collectorCrossCheck=verified)
Path(a.output).write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(dict(output=a.output,sourcePrefixUnchanged=unchanged,persistedDeltaCount=delta_count,itemResponseIdMatches=len(item_ids & response_ids),collectorCrossCheck=verified)))
