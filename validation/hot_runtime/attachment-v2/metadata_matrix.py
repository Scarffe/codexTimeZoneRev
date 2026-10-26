"""Owned-surrogate only. Matrix of bounded metadata queries under pending stdin read."""
import concurrent.futures
import ctypes as C
from ctypes import wintypes as W
import json,pathlib,queue,shutil,subprocess,sys,threading,time
ROOT=pathlib.Path(__file__).resolve().parent
V1=ROOT.parent
K=C.WinDLL('kernel32',use_last_error=True);N=C.WinDLL('ntdll')
K.OpenProcess.argtypes=[W.DWORD,W.BOOL,W.DWORD];K.OpenProcess.restype=W.HANDLE
K.GetCurrentProcess.restype=W.HANDLE
K.DuplicateHandle.argtypes=[W.HANDLE,W.HANDLE,W.HANDLE,C.POINTER(W.HANDLE),W.DWORD,W.BOOL,W.DWORD];K.DuplicateHandle.restype=W.BOOL
K.ReadProcessMemory.argtypes=[W.HANDLE,C.c_void_p,C.c_void_p,C.c_size_t,C.POINTER(C.c_size_t)];K.ReadProcessMemory.restype=W.BOOL
K.CloseHandle.argtypes=[W.HANDLE]
N.NtQueryInformationProcess.argtypes=[W.HANDLE,W.ULONG,C.c_void_p,W.ULONG,C.POINTER(W.ULONG)];N.NtQueryInformationProcess.restype=C.c_long
N.NtQueryObject.argtypes=[W.HANDLE,W.ULONG,C.c_void_p,W.ULONG,C.POINTER(W.ULONG)];N.NtQueryObject.restype=C.c_long
N.NtQueryInformationFile.argtypes=[W.HANDLE,C.c_void_p,C.c_void_p,W.ULONG,W.ULONG];N.NtQueryInformationFile.restype=C.c_long
K.GetFinalPathNameByHandleW.argtypes=[W.HANDLE,W.LPWSTR,W.DWORD,W.DWORD];K.GetFinalPathNameByHandleW.restype=W.DWORD
K.GetFileInformationByHandleEx.argtypes=[W.HANDLE,W.ULONG,C.c_void_p,W.DWORD];K.GetFileInformationByHandleEx.restype=W.BOOL
class US(C.Structure):_fields_=[('Length',W.USHORT),('MaximumLength',W.USHORT),('Buffer',C.c_void_p)]
class IOSB(C.Structure):_fields_=[('Status',C.c_void_p),('Information',C.c_size_t)]
def fixed_standard_handles(pid):
    process=K.OpenProcess(0x410,False,pid)
    try:
        basic=(C.c_uint64*6)();assert N.NtQueryInformationProcess(process,0,C.byref(basic),C.sizeof(basic),None)>=0
        params=C.c_uint64();n=C.c_size_t()
        assert K.ReadProcessMemory(process,basic[1]+0x20,C.byref(params),8,C.byref(n)) and n.value==8
        values=(C.c_uint64*3)()
        assert K.ReadProcessMemory(process,params.value+0x20,C.byref(values),24,C.byref(n)) and n.value==24
        return {'stdin':values[0],'stdout':values[1],'stderr':values[2],'bytesRead':32}
    finally:K.CloseHandle(process)
def single_query(pid,value,method):
    process=K.OpenProcess(0x40,False,pid);duplicate=W.HANDLE()
    try:
        if not process:raise C.WinError(C.get_last_error())
        if not K.DuplicateHandle(process,value,K.GetCurrentProcess(),C.byref(duplicate),0,False,2):raise C.WinError(C.get_last_error())
        start=time.perf_counter();buffer=C.create_string_buffer(65536);length=W.ULONG();iosb=IOSB()
        if method=='ObjectName':
            status=N.NtQueryObject(duplicate,1,buffer,len(buffer),C.byref(length));result={'ntstatus':hex(status&0xffffffff)}
            if status>=0:
                name=US.from_buffer(buffer);result['name']=C.wstring_at(name.Buffer,name.Length//2) if name.Buffer else ''
        elif method in ['FileName','FilePipeLocal','FileProcessIds']:
            info={'FileName':9,'FilePipeLocal':24,'FileProcessIds':47}[method]
            status=N.NtQueryInformationFile(duplicate,C.byref(iosb),buffer,len(buffer),info);result={'ntstatus':hex(status&0xffffffff),'information':iosb.Information}
            if status>=0:
                if method=='FileName':
                    byte_count=W.ULONG.from_buffer(buffer).value;result['name']=buffer.raw[4:4+byte_count].decode('utf-16le')
                if method=='FilePipeLocal':result['fields']=list((W.ULONG*10).from_buffer(buffer))
                if method=='FileProcessIds':
                    count=W.ULONG.from_buffer(buffer).value;assert count<8192
                    result['processIds']=list((C.c_size_t*count).from_buffer(buffer,8))
        elif method=='FileNameByHandleEx':
            ok=K.GetFileInformationByHandleEx(duplicate,2,buffer,len(buffer));result={'ok':bool(ok),'winerror':0 if ok else C.get_last_error()}
            if ok:
                byte_count=W.ULONG.from_buffer(buffer).value;result['name']=buffer.raw[4:4+byte_count].decode('utf-16le')
        elif method.startswith('FinalPath'):
            flags={'FinalPathOpenedNT':10,'FinalPathNormalizedNT':2}[method]
            out=C.create_unicode_buffer(32768);length=K.GetFinalPathNameByHandleW(duplicate,out,len(out),flags)
            result={'ok':bool(length),'winerror':0 if length else C.get_last_error()}
            if length:result['name']=out.value
        else:raise RuntimeError('unsupported method')
        result['queryElapsedMs']=round((time.perf_counter()-start)*1000,3)
        return result
    finally:
        if duplicate:K.CloseHandle(duplicate)
        if process:K.CloseHandle(process)
def helper_query(task):
    target,role,pid,handle,method=task
    receipt={'target':target,'role':role,'method':method,'handle':handle}
    start=time.perf_counter()
    try:
        completed=subprocess.run([sys.executable,__file__,'--query',str(pid),str(handle),method],capture_output=True,text=True,timeout=1.5,creationflags=subprocess.CREATE_NO_WINDOW)
        receipt.update(completed=True,exitCode=completed.returncode,result=json.loads(completed.stdout) if completed.stdout else None)
        if completed.returncode:receipt['error']=completed.stderr.strip()
    except subprocess.TimeoutExpired:receipt.update(completed=False,timedOut=True)
    receipt['helperElapsedMs']=round((time.perf_counter()-start)*1000,3)
    return receipt
def main():
    executable=V1/'stdio_runtime_probe.exe'
    fixture=subprocess.Popen([shutil.which('node'),str(V1/'fake_desktop.cjs')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,creationflags=subprocess.CREATE_NO_WINDOW)
    inbox=queue.Queue()
    def read():
        for line in fixture.stdout:inbox.put(json.loads(line))
    threading.Thread(target=read,daemon=True).start()
    ready=inbox.get(timeout=10)
    assert ready['event']=='fixture-ready',ready
    result={'status':'RUNNING','realCodexProcessAccess':False,'modelRequests':0}
    try:
        fixture.stdin.write(json.dumps({'type':'normal-write','seq':'pending-read-baseline'})+'\n');fixture.stdin.flush();baseline=inbox.get(timeout=5)
        assert baseline['message']['id']=='normal-pending-read-baseline',baseline
        standards=fixed_standard_handles(ready['childPid']);result['standardHandles']=standards
        identity_args=['--parent-pid',str(ready['parentPid']),'--child-pid',str(ready['childPid'])]
        first=subprocess.run([str(executable),'--identity-only',*identity_args],capture_output=True,text=True,check=True,creationflags=subprocess.CREATE_NO_WINDOW)
        identity=json.loads(first.stdout);pinned=list(identity_args)
        for role in ['parent','child']:pinned.extend([f'--{role}-created',str(identity[role]['created']),f'--{role}-path',identity[role]['path']])
        enumerated=subprocess.run([str(executable),'--enum-only',*pinned],capture_output=True,text=True,check=True,timeout=40,creationflags=subprocess.CREATE_NO_WINDOW)
        parent_pipes=json.loads(enumerated.stdout)['pipes'];result['parentPipeCandidates']=parent_pipes
        methods=['ObjectName','FileName','FilePipeLocal','FileProcessIds','FileNameByHandleEx','FinalPathOpenedNT','FinalPathNormalizedNT']
        tasks=[('child',role,ready['childPid'],standards[role],method) for role in ['stdin','stdout','stderr'] for method in methods]
        tasks += [('parent','pipe-'+str(index),ready['parentPid'],pipe['handle'],method) for index,pipe in enumerate(parent_pipes) for method in methods]
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:receipts=list(pool.map(helper_query,tasks))
        fixture.stdin.write(json.dumps({'type':'normal-write','seq':'after-metadata'})+'\n');fixture.stdin.flush();after=inbox.get(timeout=5)
        assert after['message']['id']=='normal-after-metadata',after
        last=subprocess.run([str(executable),'--identity-only',*identity_args],capture_output=True,text=True,check=True,creationflags=subprocess.CREATE_NO_WINDOW)
        assert identity==json.loads(last.stdout)
        result.update(status='COMPLETE_ISOLATED_METADATA_MATRIX',fixtureParentPid=ready['parentPid'],fixtureChildPid=ready['childPid'],parentAndChildIdentityUnchanged=True,originalReaderStillWorks=True,queries=receipts)
        (ROOT/'metadata-matrix-result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
        print(json.dumps({'status':result['status'],'childStdin':[{k:r[k]for k in ['method','completed']for _ in [0]}|({'result':r['result']} if 'result'in r else{}) for r in receipts if r['target']=='child'and r['role']=='stdin'],'parentPipeCount':len(parent_pipes),'queryCount':len(receipts),'parentAndChildIdentityUnchanged':True},indent=2))
    except Exception as error:
        result.update(status='FAILED_ISOLATED_METADATA_MATRIX',error=str(error));(ROOT/'metadata-matrix-failure.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');raise
    finally:
        if fixture.poll()is None:
            fixture.stdin.write(json.dumps({'type':'exit'})+'\n');fixture.stdin.flush()
            try:fixture.wait(timeout=5)
            except subprocess.TimeoutExpired:fixture.kill();fixture.wait()
if __name__=='__main__':
    if len(sys.argv)>1 and sys.argv[1]=='--query':print(json.dumps(single_query(int(sys.argv[2]),int(sys.argv[3]),sys.argv[4])),flush=True)
    else:main()
