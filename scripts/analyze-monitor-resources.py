"""Analyze bounded monitor samples without third-party Python dependencies."""
import argparse
import csv
import json
from collections import defaultdict
from pathlib import Path
from statistics import mean, median

parser=argparse.ArgumentParser()
parser.add_argument('csv',type=Path)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
rows=list(csv.DictReader(args.csv.open(encoding='utf-8-sig',newline='')))
def number(r,key): return float(r[key])
def flag(r,key): return r[key].lower()=='true'
warm=[r for r in rows if number(r,'elapsedSeconds')>=60]
intervals=[r for p,r in zip(rows,rows[1:])
    if number(p,'elapsedSeconds')>=60 and r['soakStep']==p['soakStep']]
violations=[]
for p,r in zip(rows,rows[1:]):
    if r['soakStep']==p['soakStep'] and not flag(p,'timer') and not flag(r,'timer'):
        if r['frames']!=p['frames']: violations.append({'step':r['soakStep'],'frames':[p['frames'],r['frames']]})
groups=defaultdict(lambda:defaultdict(list))
for r in warm:
    step=int(r['soakStep'])
    if step>=0: groups[(int(r['mode']),step%8)][step//24].append(r)
comparisons=[]
for (mode,phase),cycles in groups.items():
    keys=sorted(cycles)
    if len(keys)<2: continue
    a,b=cycles[keys[0]],cycles[keys[-1]]
    delta={key:round(median(number(r,key) for r in b)-median(number(r,key) for r in a),3)
        for key in ['privateMiB','processHandles','gdiObjects']}
    comparisons.append({'mode':mode,'phase':phase,'firstCycle':keys[0],'lastCycle':keys[-1],**delta})
active=defaultdict(list)
for r in intervals:
    if flag(r,'timer'): active[(r['mode'],r['state'])].append(number(r,'cpuOneCorePercent'))
cpu=[{'mode':int(k[0]),'state':int(k[1]),'samples':len(v),'meanOneCorePercent':round(mean(v),3),
      'peakOneCorePercent':round(max(v),3)} for k,v in sorted(active.items())]
checks={
    'duration':bool(rows) and number(rows[-1],'elapsedSeconds')>=710 and len(rows)>=140,
    'threeModes':set(r['mode'] for r in warm)=={'0','1','2'},
    'allPhases':set(int(r['soakStep'])%8 for r in warm)==set(range(8)),
    'mainWindowStayedHidden':not any(flag(r,'mainVisible') for r in rows),
    'noDrawFailures':all(number(r,'drawFailures')==0 for r in rows),
    'noForegroundPet':not any(flag(r,'petForeground') for r in rows),
    'stoppedFramesFrozen':not violations,
    'timersOffWhenStopped':all(not flag(r,'timer') for r in rows
      if flag(r,'reduced') or not flag(r,'visible') or flag(r,'suspended') or r['state']=='3'),
    'animatedFramesObserved':bool(rows) and number(rows[-1],'frames')-number(rows[0],'frames')>=500,
    'cpuBudget':len(cpu)==9 and all(r['meanOneCorePercent']<=10 for r in cpu),
    'memoryBudget':len(comparisons)==24 and all(r['privateMiB']<=16 for r in comparisons),
    'gdiBudget':bool(comparisons) and all(r['gdiObjects']<=8 for r in comparisons),
    'handleBudget':bool(comparisons) and all(r['processHandles']<=32 for r in comparisons),
    'queriesContinue':bool(rows) and number(rows[-1],'revision')-number(rows[0],'revision')>=4,
    'noQueryFailures':all(number(r,'failures')==0 for r in rows),
    'noExtraAnimationQueries':bool(rows) and number(rows[-1],'attempts')-number(rows[0],'attempts')<=int(number(rows[-1],'elapsedSeconds')//120)+2,
}
result={'passed':all(checks.values()),'checks':checks,'samples':len(rows),
    'durationSeconds':number(rows[-1],'elapsedSeconds') if rows else 0,
    'cpuExplanation':'100 percent = one logical core. Per-mode CPU uses complete intervals in one phase; first 60 seconds excluded.',
    'cpuByModeAndState':cpu,'samePhaseCycleDeltas':comparisons,'stoppedFrameViolations':violations}
if warm:
    result['warmSummary']={k:{'min':round(min(number(r,k) for r in warm),3),
        'max':round(max(number(r,k) for r in warm),3),'mean':round(mean(number(r,k) for r in warm),3)}
        for k in ['privateMiB','workingMiB','processHandles','gdiObjects','userObjects','cpuOneCorePercent','cpuMachinePercent']}
    result['queries']={'first':int(rows[0]['attempts']),'last':int(rows[-1]['attempts']),
        'firstRevision':int(rows[0]['revision']),'lastRevision':int(rows[-1]['revision'])}
args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'passed':result['passed'],'samples':result['samples'],'durationSeconds':result['durationSeconds'],'checks':checks},ensure_ascii=False))

raise SystemExit(0 if result['passed'] else 1)
