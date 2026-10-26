"""Owned-only acceptance of the production v3 live/auth hooks and original Node stream."""
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
sys.dont_write_bytecode = True
import run_owned_node_observer as base

ROOT=Path(__file__).resolve().parent
K=base.K
class Id(C.Structure):
    _fields_=[('kind',W.DWORD),('length',W.DWORD),('number',C.c_int64),('text',C.c_char*64)]
class Control(C.Structure):
    _fields_=[('state',W.LONG),('purpose',W.DWORD),('generation',C.c_uint64),('ticket',C.c_uint64),('id',Id)]
class Event(C.Structure):
    _fields_=[('kind',W.DWORD),('method',W.DWORD),('direction',W.DWORD),('flags',W.DWORD),
        ('generation',C.c_uint64),('sequence',C.c_uint64),('observedAtMs',C.c_uint64),('id',Id),
        ('rpcErrorCode',C.c_int32),('authMode',W.DWORD),('accountType',W.DWORD),('refreshReason',W.DWORD),
        ('emailBytes',W.DWORD),('planBytes',W.DWORD),('accountIdBytes',W.DWORD),('replyType',W.DWORD),
        ('email',C.c_char*320),('plan',C.c_char*64),('accountId',C.c_char*128)]
COUNTERS=('state','enabled','head','tail','drops','lines','rejects','duplicateRejects','immediate','pending','gor',
    'gorAborted','zeroReads','apiInvariant','coalesced','fragmented','iatRestored','protectionRestored',
    'writerMatchedPairs','writerReady','coverageFlags','writerFrames','ownedControlsObserved','reservedCounter')
class LiveEvent(C.Structure):
    _fields_=[('generation',C.c_uint64),('sequence',C.c_uint64),('observedAtMs',C.c_uint64),
        ('kind',W.DWORD),('lifecycle',W.DWORD),('attention',W.DWORD),('flags',W.DWORD),('requestId',Id),
        ('threadId',C.c_char*64),('turnId',C.c_char*64)]
class Shared(C.Structure):
    _fields_=[(n,W.DWORD)for n in ('magic','version','bytes','eventBytes','controlBytes','brokerPid','ownerPid','childPid')]+[
        (n,C.c_uint64)for n in ('generation','readerHandle','candidateWriter')]+[(n,W.LONG)for n in COUNTERS]+[
        ('controls',Control*8),('events',Event*16)]+[(n,W.LONG)for n in ('liveHead','liveTail','liveDrops','liveCoverageFlags','livePublished','liveRejected','liveOutstanding','liveReserved')]+[('liveEvents',LiveEvent*16)]
class HandleProof(C.Structure):
    _fields_=base.HandleProof._fields_+[('candidateWriter',C.c_uint64)]
class Config(C.Structure):
    _fields_=[('magic',W.DWORD),('version',W.DWORD),('bytes',W.DWORD),('role',W.DWORD),('ownerGeneration',C.c_uint64),
        ('expectedModule',base.ModuleProof),('establishedStdio',HandleProof),('mappingVersion',W.DWORD),
        ('mappingBytes',W.DWORD),('mappingName',W.WCHAR*196)]
assert C.sizeof(Id)==80 and C.sizeof(Control)==104 and C.sizeof(Event)==664
assert Shared.controls.offset==152 and Shared.events.offset==984 and C.sizeof(Shared)==15608 and Shared.liveEvents.offset==11640 and C.sizeof(LiveEvent)==248
assert C.sizeof(Config)==512 and Config.mappingName.offset==120

class Owned(base.Owned):
    def pin(self):
        generation_ok=self.shared is None or (self.shared.generation==self.generation and self.shared.ownerPid==self.parent['pid'] and self.shared.childPid==self.child['pid'])
        if not generation_ok or self.process.poll()is not None or not base.locator.pinned_equal(base.locator.identity(self.parent['pid']),self.parent) or not base.locator.pinned_equal(base.locator.identity(self.child['pid']),self.child):
            raise RuntimeError('owned_identity_changed')
    def start_v3(self,address,name):
        config=Config();config.magic=0x434f4e46;config.version=3;config.bytes=C.sizeof(config);config.role=1
        config.ownerGeneration=self.generation;config.mappingVersion=3;config.mappingBytes=C.sizeof(Shared);config.mappingName=name
        disk=base.APPROVED_NODE.read_bytes();pe=struct.unpack_from('<I',disk,0x3c)[0]
        config.expectedModule.imageSize=struct.unpack_from('<I',disk,pe+24+56)[0]
        config.expectedModule.imageTimestamp=struct.unpack_from('<I',disk,pe+8)[0]
        config.expectedModule.sha256[:]=bytes.fromhex(base.NODE_SHA256)
        proof=config.establishedStdio;proof.exactStdoutReader=self.shared.readerHandle;proof.candidateWriter=self.shared.candidateWriter
        proof.ownerPid,proof.childPid=self.parent['pid'],self.child['pid'];proof.ownerCreationFileTime,proof.childCreationFileTime=self.parent['created'],self.child['created']
        remote=base.required(self.operation(K.VirtualAllocEx,self.handle,None,C.sizeof(config),0x3000,4))
        try:
            written=C.c_size_t();base.required(self.operation(K.WriteProcessMemory,self.handle,remote,C.byref(config),C.sizeof(config),C.byref(written)))
            if written.value!=C.sizeof(config):raise RuntimeError('config_copy_incomplete')
            return self.remote_thread(address,remote)
        finally:
            if not self.remote_timed_out:base.required(self.operation(K.VirtualFreeEx,self.handle,remote,0,0x8000))

def run(args):
    receipt=Path(args.receipt)
    if receipt.exists():raise RuntimeError('preserve_existing_receipt')
    result={'pass':False,'realDesktopAccess':False,'modelRequests':0,'credentialReads':0,'sideWrites':0,'stage':0}
    process=None;owned=None;module=None;mapping=None;view=None;shared=None;stopped=False
    try:
        dll=Path(args.dll or ROOT/'v3_node_observer.dll').resolve(strict=True)
        if dll.name.casefold()!='v3_node_observer.dll' or hashlib.sha256(base.APPROVED_NODE.read_bytes()).hexdigest()!=base.NODE_SHA256:raise RuntimeError('artifact_or_node_mismatch')
        exports=base.exports(dll)
        work=ROOT/('v3-owned-temp-'+secrets.token_hex(8));work.mkdir()
        system=os.environ.get('SystemRoot',r'C:\Windows');env={'SystemRoot':system,'WINDIR':system,'TEMP':str(work),'TMP':str(work)}
        process=subprocess.Popen([str(base.APPROVED_NODE),str(ROOT/'v3_live_parent.cjs')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf8',env=env,cwd=ROOT,creationflags=subprocess.CREATE_NO_WINDOW)
        inbox=queue.Queue()
        def read_control():
            for line in process.stdout:
                try:inbox.put(json.loads(line))
                except ValueError:inbox.put(None)
        threading.Thread(target=read_control,daemon=True).start()
        spawn=inbox.get(timeout=10)
        if not spawn or spawn.get('event')!='spawned' or spawn.get('parentPid')!=process.pid:raise RuntimeError('startup')
        owned=Owned(process,spawn['childPid']);owned.pin()
        process.stdin.write('warmup\n');process.stdin.flush();baseline=inbox.get(timeout=10)
        if baseline.get('event')!='baseline-complete' or baseline.get('frames')!=3 or not baseline.get('byteEqual') or not baseline.get('hashEqual'):raise RuntimeError('baseline')
        owned.pin();result['baselineRpcCount']=3;result['stage']=1
        located=base.locator.locate(owned.parent,owned.child);owned.pin()
        readers=[x['handle']for x in located['allConnectedPipes']if x['name']==located['excludedStdoutName']and x['access']&1]
        if len(readers)!=1:raise RuntimeError('reader_proof')
        generation=secrets.randbits(64)or 1;name='Local\\CtzOwnedV3-'+str(os.getpid())+'-'+f'{generation:016x}'
        mapping=base.required(K.CreateFileMappingW(C.c_void_p(-1),None,4,0,C.sizeof(Shared),name))
        if C.get_last_error()==183:raise RuntimeError('mapping_exists')
        view=base.required(K.MapViewOfFile(mapping,0xf001f,0,0,C.sizeof(Shared)));C.memset(view,0,C.sizeof(Shared));shared=Shared.from_address(view)
        shared.magic,shared.version,shared.bytes=0x4f4e4f42,3,C.sizeof(Shared);shared.eventBytes,shared.controlBytes=C.sizeof(Event),C.sizeof(Control)
        shared.brokerPid,shared.ownerPid,shared.childPid=os.getpid(),owned.parent['pid'],owned.child['pid'];shared.generation=generation
        shared.readerHandle,shared.candidateWriter=readers[0],located['stdinWriter']['handle'];owned.shared,owned.generation=shared,generation
        module=owned.load(dll);status=owned.start_v3(module+exports['Start'],name);result['startStatus']=status
        if status!=1 or shared.state!=1 or shared.writerReady:raise RuntimeError('start')
        result['stage']=2;owned.pin();process.stdin.write('probe\n');process.stdin.flush();owned.pin()
        probe=inbox.get(timeout=15)
        if probe.get('event')!='probe-complete' or probe.get('frames')!=19 or not probe.get('byteEqual') or not probe.get('hashEqual') or not probe.get('stderrEmpty') or probe.get('replyCount')!=2:raise RuntimeError('original_probe_stream')
        deadline=time.monotonic()+5
        while time.monotonic()<deadline and not shared.writerReady:owned.pin();time.sleep(.01)
        owned.pin();events=[Event.from_buffer_copy(shared.events[i%16])for i in range(shared.tail,shared.head)]
        privacy=all(e.kind in (1,2) and not e.emailBytes and not e.planBytes and not e.accountIdBytes and not bytes(e.email)and not bytes(e.plan)and not bytes(e.accountId)for e in events)
        sequence=all(e.sequence==i+1 and e.generation==generation for i,e in enumerate(events))
        live=[LiveEvent.from_buffer_copy(shared.liveEvents[i%16])for i in range(shared.liveTail,shared.liveHead)]
        kinds=[1,2,4,7,4,4,5,8,5,6,1,1,3,3,3]
        live_kinds=len(live)==15 and [e.kind for e in live]==kinds
        live_sequence=all(e.sequence==i+1 and e.generation==generation for i,e in enumerate(live))
        live_context=all(bytes(e.threadId)==b'thread-A' for e in live)
        typed=live_kinds and live[2].requestId.kind==1 and live[2].requestId.number==17 and live[3].requestId.kind==1 and live[3].requestId.number==17 and shared.liveOutstanding==4
        lifecycle=live_kinds and [live[i].lifecycle for i in (1,11,12,13,14)]==[5,2,7,8,6]
        blocking=live_kinds and live[6].flags&48==48 and live[8].flags&16 and not live[8].flags&32 and live[9].flags&8 and not bytes(live[9].turnId)
        live_private=b'SYNTHETIC_LIVE_BODY_ea04b9' not in bytes(shared)
        live_good=bool(live_kinds and live_sequence and live_context and typed and lifecycle and blocking and live_private and shared.liveCoverageFlags==3 and not shared.liveDrops and not shared.liveRejected)
        result.update(liveEvents=len(live),liveKindsValid=live_kinds,liveSequencesValid=live_sequence,liveContextsValid=live_context,
            exactTypedReply=typed,lifecycleDistinct=lifecycle,blockingDistinct=bool(blocking),livePrivateBodyExcluded=live_private,
            liveDrops=shared.liveDrops,liveCoverageFlags=shared.liveCoverageFlags,liveOutstanding=shared.liveOutstanding,
            clientReplyWrites=2,authWrites=0,realLiveCoverageRun=False)
        result.update(naturalRpcCount=2,originalProbeBytes=probe['bytes'],originalProbeFrames=probe['frames'],originalProbeHashEqual=True,
            observerFrames=shared.lines,writerFrames=shared.writerFrames,writerMatchedPairs=shared.writerMatchedPairs,writerReady=bool(shared.writerReady),
            observerDrops=shared.drops,coverageFlags=shared.coverageFlags,events=len(events),naturalIdentityNotExported=privacy,
            eventSequencesValid=sequence,completedBuffersUnchanged=bool(shared.apiInvariant),identitiesUnchanged=True,
            pendingReads=shared.pending,gorCompletions=shared.gor,accountProjectionRun=False,actualAuthSwitchRun=False)
        result['pass']=bool(shared.writerReady and shared.writerMatchedPairs==2 and shared.lines==19 and shared.writerFrames==4 and not shared.drops and not shared.coverageFlags and shared.apiInvariant and privacy and sequence and len(events)==2 and live_good and probe['bytes']>=262144)
        result['stage']=3;status=owned.remote_thread(module+exports['Stop']);result['stopStatus']=status
        stopped=status==2 and shared.state==2 and bool(shared.iatRestored)and bool(shared.protectionRestored)
        result['iatRestored']=bool(shared.iatRestored);result['protectionRestored']=bool(shared.protectionRestored)
        result['pass']=result['pass']and stopped
    except Exception as error:
        result['failure']=True;result['windowsError']=int(getattr(error,'winerror',0)or 0)
    finally:
        if owned and module and not stopped and process.poll()is None and not owned.remote_timed_out:
            try:result['cleanupStopStatus']=owned.remote_thread(module+exports['Stop'])
            except Exception:pass
        if process and process.poll()is None:
            try:process.stdin.write('exit\n');process.stdin.flush();process.wait(timeout=5)
            except Exception:process.kill();process.wait(timeout=5)
        if process:result['ownedExitZero']=process.returncode==0;result['pass']=result['pass']and result['ownedExitZero']
        if owned:owned.shared=None
        shared=None
        if view:K.UnmapViewOfFile(view)
        if mapping:K.CloseHandle(mapping)
    encoded=json.dumps(result,separators=(',',':'))+'\n';receipt.write_text(encoded,encoding='utf8');print(encoded,end='')
    return 0 if result['pass']else 1

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--dll');parser.add_argument('--receipt',required=True)
    raise SystemExit(run(parser.parse_args()))
