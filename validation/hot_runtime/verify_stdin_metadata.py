import ctypes as C
from ctypes import wintypes as W
import json,pathlib,queue,shutil,subprocess,sys,threading
K=C.WinDLL('kernel32',use_last_error=True);N=C.WinDLL('ntdll')
K.OpenProcess.argtypes=[W.DWORD,W.BOOL,W.DWORD];K.OpenProcess.restype=W.HANDLE
K.GetCurrentProcess.restype=W.HANDLE
K.DuplicateHandle.argtypes=[W.HANDLE,W.HANDLE,W.HANDLE,C.POINTER(W.HANDLE),W.DWORD,W.BOOL,W.DWORD];K.DuplicateHandle.restype=W.BOOL
K.ReadProcessMemory.argtypes=[W.HANDLE,C.c_void_p,C.c_void_p,C.c_size_t,C.POINTER(C.c_size_t)];K.ReadProcessMemory.restype=W.BOOL
K.CloseHandle.argtypes=[W.HANDLE]
N.NtQueryInformationProcess.argtypes=[W.HANDLE,W.ULONG,C.c_void_p,W.ULONG,C.POINTER(W.ULONG)];N.NtQueryInformationProcess.restype=C.c_long
N.NtQueryObject.argtypes=[W.HANDLE,W.ULONG,C.c_void_p,W.ULONG,C.POINTER(W.ULONG)];N.NtQueryObject.restype=C.c_long
class US(C.Structure):_fields_=[('Length',W.USHORT),('Max',W.USHORT),('Buffer',C.c_void_p)]
def readptr(h,addr):
 v=C.c_uint64();n=C.c_size_t()
 if not K.ReadProcessMemory(h,addr,C.byref(v),8,C.byref(n)) or n.value!=8:raise C.WinError(C.get_last_error())
 return v.value
def metadata(pid):
 h=K.OpenProcess(0x410,False,pid)
 try:
  b=(C.c_uint64*6)()
  assert N.NtQueryInformationProcess(h,0,C.byref(b),C.sizeof(b),None)>=0
  params=readptr(h,b[1]+0x20);stdin=readptr(h,params+0x20)
  return {'stdinHandle':stdin,'processMemoryBytesRead':16,'reads':['PEB.ProcessParameters pointer','RTL_USER_PROCESS_PARAMETERS.StandardInput handle']}
 finally:K.CloseHandle(h)
def name(pid,handle):
 h=K.OpenProcess(0x40,False,pid);d=W.HANDLE()
 try:
  assert K.DuplicateHandle(h,handle,K.GetCurrentProcess(),C.byref(d),0,False,2)
  buf=C.create_string_buffer(65536);need=W.ULONG()
  status=N.NtQueryObject(d,1,buf,len(buf),C.byref(need));u=US.from_buffer(buf)
  return {'status':status,'name':C.wstring_at(u.Buffer,u.Length//2) if status>=0 and u.Buffer else ''}
 finally:
  if d:K.CloseHandle(d)
  K.CloseHandle(h)
if len(sys.argv)>1:
 print(json.dumps(name(int(sys.argv[1]),int(sys.argv[2]))),flush=True);sys.exit(0)
root=pathlib.Path(__file__).resolve().parent
p=subprocess.Popen([shutil.which('node'),str(root/'fake_desktop.cjs')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,creationflags=subprocess.CREATE_NO_WINDOW)
q=queue.Queue()
def reader():
 for line in p.stdout:q.put(json.loads(line))
threading.Thread(target=reader,daemon=True).start()
ready=q.get(timeout=10);print('READY',ready,flush=True)
try:
 p.stdin.write(json.dumps({'type':'normal-write','seq':'pending-read-confirmed'})+'\n');p.stdin.flush();q.get(timeout=5)
 m=metadata(ready['childPid']);print('METADATA',m,flush=True)
 try:
  r=subprocess.run([sys.executable,__file__,str(ready['childPid']),str(m['stdinHandle'])],capture_output=True,text=True,timeout=2,creationflags=subprocess.CREATE_NO_WINDOW)
  query={'completed':True,'exitCode':r.returncode,'result':json.loads(r.stdout) if r.stdout else None}
 except subprocess.TimeoutExpired:query={'completed':False,'timedOut':True}
 result={'status':'SURROGATE_METADATA_ONLY','fixtureParentPid':ready['parentPid'],'fixtureChildPid':ready['childPid'],**m,'directObjectNameQuery':query,'realCodexProcessAccess':False,'networkRequests':0}
 (root/'stdin-metadata-fixture-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2),flush=True)
finally:
 p.stdin.write(json.dumps({'type':'exit'})+'\n');p.stdin.flush()
 try:p.wait(timeout=3)
 except subprocess.TimeoutExpired:p.kill();p.wait()
