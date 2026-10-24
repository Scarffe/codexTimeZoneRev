using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace K32Probe
{
    public sealed class ProbeException : Exception
    {
        public string ReasonCode { get; private set; }
        internal ProbeException(string reason) : base(reason) { ReasonCode = reason; }
    }
    public sealed class ProcessIdentity
    {
        public int Pid { get; private set; }
        private ProcessIdentity(int pid) { Pid = pid; }
        internal static ProcessIdentity Create(int pid) { return new ProcessIdentity(pid); }
    }
    public sealed class CleanupReceipt
    {
        public bool ProcessReaped { get; private set; }
        public bool JobEmpty { get; private set; }
        public bool ReaderJoined { get; private set; }
        public bool WriterJoined { get; private set; }
        public bool Confirmed { get { return ProcessReaped && JobEmpty && ReaderJoined && WriterJoined; } }
        internal CleanupReceipt(bool p, bool j, bool r, bool w) { ProcessReaped=p; JobEmpty=j; ReaderJoined=r; WriterJoined=w; }
    }

    // Diagnostic transport only. Protocol authorization belongs to its caller.
    public sealed class OwnedStdioChild : IDisposable
    {
        const int FrameLimit = 1048576;
        const int QueueLimit = 32;
        readonly object state = new object(), sendGate = new object(), stopGate = new object();
        readonly Queue<string> frames = new Queue<string>();
        readonly AutoResetEvent writerWake = new AutoResetEvent(false);
        readonly UTF8Encoding utf8 = new UTF8Encoding(false, true);
        IntPtr job, process, stdinWrite, stdoutRead;
        Thread reader, writer;
        bool stopping, poisoned;
        string readError;
        WriteRequest pending;
        CleanupReceipt receipt;
        public ProcessIdentity Identity { get; private set; }
        public bool CreatedSuspended { get; private set; }
        public bool JobAssignedBeforeResume { get; private set; }
        public int InheritedHandleCount { get; private set; }
        private OwnedStdioChild() { }
        sealed class WriteRequest { internal byte[] Bytes; internal bool Done; internal string Error; }

        public static OwnedStdioChild Start(string executable, string[] args, string cwd, IDictionary<string,string> childEnvironment)
        {
            var c = new OwnedStdioChild();
            IntPtr stdinRead=IntPtr.Zero, stdoutWrite=IntPtr.Zero, stderr=IntPtr.Zero;
            IntPtr attributes=IntPtr.Zero, handles=IntPtr.Zero, env=IntPtr.Zero, primaryThread=IntPtr.Zero;
            bool attributesInitialized=false;
            try
            {
                if (String.IsNullOrEmpty(executable) || !Path.IsPathRooted(executable) || executable.StartsWith(@"\\", StringComparison.Ordinal) ||
                    executable.IndexOf('\0') >= 0 || String.IsNullOrEmpty(cwd) || !Path.IsPathRooted(cwd) || cwd.IndexOf('\0') >= 0 ||
                    args == null || childEnvironment == null) throw new ProbeException("invalid_start_input");
                var command = new StringBuilder(Quote(executable));
                foreach (string arg in args) { if (arg == null || arg.IndexOf('\0') >= 0) throw new ProbeException("invalid_start_input"); command.Append(' ').Append(Quote(arg)); }
                if (command.Length >= 32767) throw new ProbeException("invalid_start_input");
                var sorted = new SortedDictionary<string,string>(StringComparer.OrdinalIgnoreCase);
                foreach (var pair in childEnvironment)
                {
                    if (String.IsNullOrEmpty(pair.Key) || pair.Key.IndexOfAny(new char[]{'=', '\0'}) >= 0 || pair.Value == null || pair.Value.IndexOf('\0') >= 0 || sorted.ContainsKey(pair.Key))
                        throw new ProbeException("invalid_environment");
                    sorted.Add(pair.Key, pair.Value);
                }
                var environment = new StringBuilder();
                foreach (var pair in sorted) environment.Append(pair.Key).Append('=').Append(pair.Value).Append('\0');
                environment.Append('\0');
                if (sorted.Count == 0) environment.Append('\0');
                env=Marshal.StringToHGlobalUni(environment.ToString());
                c.job=Native.CreateJobObject(IntPtr.Zero, null);
                if (c.job == IntPtr.Zero) throw new ProbeException("job_create_failed");
                var limits = new Native.JobExtendedLimits();
                limits.BasicLimitInformation.LimitFlags=0x2000; // KILL_ON_JOB_CLOSE; no breakaway.
                if (!Native.SetInformationJobObject(c.job,9,ref limits,(uint)Marshal.SizeOf(typeof(Native.JobExtendedLimits)))) throw new ProbeException("job_setup_failed");
                var sa = new Native.SecurityAttributes { Length=Marshal.SizeOf(typeof(Native.SecurityAttributes)), InheritHandle=1 };
                if (!Native.CreatePipe(out stdinRead,out c.stdinWrite,ref sa,0)) throw new ProbeException("pipe_create_failed");
                if (!Native.SetHandleInformation(c.stdinWrite,1,0)) throw new ProbeException("pipe_setup_failed");
                if (!Native.CreatePipe(out c.stdoutRead,out stdoutWrite,ref sa,0)) throw new ProbeException("pipe_create_failed");
                if (!Native.SetHandleInformation(c.stdoutRead,1,0)) throw new ProbeException("pipe_setup_failed");
                stderr=Native.CreateFile("NUL",0x40000000,3,ref sa,3,0,IntPtr.Zero);
                if (stderr==new IntPtr(-1)) { stderr=IntPtr.Zero; throw new ProbeException("stderr_setup_failed"); }
                IntPtr size=IntPtr.Zero;
                Native.InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref size);
                attributes=Marshal.AllocHGlobal(size);
                if (!Native.InitializeProcThreadAttributeList(attributes,1,0,ref size)) throw new ProbeException("attribute_setup_failed");
                attributesInitialized=true;
                handles=Marshal.AllocHGlobal(3*IntPtr.Size);
                Marshal.WriteIntPtr(handles,0,stdinRead); Marshal.WriteIntPtr(handles,IntPtr.Size,stdoutWrite); Marshal.WriteIntPtr(handles,2*IntPtr.Size,stderr);
                if (!Native.UpdateProcThreadAttribute(attributes,0,new IntPtr(0x20002),handles,new IntPtr(3*IntPtr.Size),IntPtr.Zero,IntPtr.Zero)) throw new ProbeException("attribute_setup_failed");
                var startup=new Native.StartupInfoEx();
                startup.StartupInfo.Size=Marshal.SizeOf(typeof(Native.StartupInfoEx));
                startup.StartupInfo.Flags=0x100;
                startup.StartupInfo.StdInput=stdinRead; startup.StartupInfo.StdOutput=stdoutWrite; startup.StartupInfo.StdError=stderr;
                startup.AttributeList=attributes;
                Native.ProcessInformation pi;
                if (!Native.CreateProcess(executable,command,IntPtr.Zero,IntPtr.Zero,true,0x4|0x08000000|0x400|0x80000,env,cwd,ref startup,out pi)) throw new ProbeException("start_failed");
                c.process=pi.Process; primaryThread=pi.Thread;
                c.Identity=ProcessIdentity.Create(unchecked((int)pi.ProcessId));
                c.CreatedSuspended=true; c.InheritedHandleCount=3;
                // Parent copies must not keep pipes open if a later startup stage fails.
                Close(ref stdinRead); Close(ref stdoutWrite); Close(ref stderr);
                if (!Native.AssignProcessToJobObject(c.job,c.process)) throw new ProbeException("job_assignment_failed");
                c.JobAssignedBeforeResume=true;
                c.reader=new Thread(c.ReadWorker) { IsBackground=true, Name="K32 owned stdout" };
                c.writer=new Thread(c.WriteWorker) { IsBackground=true, Name="K32 owned stdin" };
                c.reader.Start(); c.writer.Start();
                if (Native.ResumeThread(primaryThread)==UInt32.MaxValue) throw new ProbeException("resume_failed");
                Close(ref primaryThread);
                return c;
            }
            catch (Exception error)
            {
                // The process handle came only from our successful CreateProcess call.
                bool reaped=true;
                if (c.process!=IntPtr.Zero)
                {
                    Native.TerminateProcess(c.process,1);
                    if (c.job!=IntPtr.Zero) Native.TerminateJobObject(c.job,1);
                    reaped=Native.WaitForSingleObject(c.process,5000)==0;
                }
                lock(c.state) { c.stopping=true; Monitor.PulseAll(c.state); }
                c.writerWake.Set();
                if (c.reader!=null && c.reader.IsAlive) reaped &= c.reader.Join(1000);
                if (c.writer!=null && c.writer.IsAlive) reaped &= c.writer.Join(1000);
                // A live worker still owns these resources. Its strong owner reference
                // preserves them until it exits; do not invalidate them on a join timeout.
                if (!reaped) throw new ProbeException("start_cleanup_unconfirmed");
                c.CloseOwnedHandles();
                c.writerWake.Dispose();
                GC.SuppressFinalize(c);
                var safe=error as ProbeException;
                throw safe ?? new ProbeException("start_failed");
            }
            finally
            {
                Close(ref primaryThread); Close(ref stdinRead); Close(ref stdoutWrite); Close(ref stderr);
                if(attributesInitialized) Native.DeleteProcThreadAttributeList(attributes);
                if(attributes!=IntPtr.Zero) Marshal.FreeHGlobal(attributes);
                if(handles!=IntPtr.Zero) Marshal.FreeHGlobal(handles);
                if(env!=IntPtr.Zero) Marshal.FreeHGlobal(env);
            }
        }

        static string Quote(string value)
        {
            var result=new StringBuilder("\""); int slashes=0;
            foreach(char ch in value)
            {
                if(ch=='\\') { slashes++; continue; }
                if(ch=='"') { result.Append('\\',slashes*2+1).Append(ch); slashes=0; continue; }
                result.Append('\\',slashes).Append(ch); slashes=0;
            }
            return result.Append('\\',slashes*2).Append('"').ToString();
        }
        static void ValidateTimeout(int timeoutMs) { if(timeoutMs<1 || timeoutMs>60000) throw new ProbeException("invalid_timeout"); }
        static int Left(Stopwatch clock,int budget) { return (int)Math.Max(0,budget-clock.ElapsedMilliseconds); }

        public void WriteLine(string line,int timeoutMs)
        {
            ValidateTimeout(timeoutMs);
            if(line==null || line.Length>FrameLimit || line.IndexOfAny(new char[]{'\r','\n'})>=0) throw new ProbeException("invalid_write_frame");
            byte[] bytes;
            try { if(utf8.GetByteCount(line)>FrameLimit) throw new ProbeException("frame_too_large"); bytes=utf8.GetBytes(line+"\n"); }
            catch(EncoderFallbackException) { throw new ProbeException("invalid_utf8"); }
            var clock=Stopwatch.StartNew();
            if(!Monitor.TryEnter(sendGate,timeoutMs)) { lock(state) { poisoned=true; } throw new ProbeException("write_timeout"); }
            try
            {
                lock(state)
                {
                    if(stopping) throw new ProbeException("child_stopped");
                    if(poisoned) throw new ProbeException("write_poisoned");
                    var request=new WriteRequest { Bytes=bytes };
                    pending=request; writerWake.Set();
                    while(!request.Done && !stopping)
                    {
                        int left=Left(clock,timeoutMs);
                        if(left==0) { poisoned=true; throw new ProbeException("write_timeout"); }
                        Monitor.Wait(state,left);
                    }
                    if(!request.Done) { poisoned=true; throw new ProbeException("child_stopped"); }
                    if(request.Error!=null) { poisoned=true; throw new ProbeException(request.Error); }
                }
            }
            finally { Monitor.Exit(sendGate); }
        }

        public string ReadLine(int timeoutMs)
        {
            ValidateTimeout(timeoutMs); var clock=Stopwatch.StartNew();
            lock(state)
            {
                while(true)
                {
                    // EOF follows already received complete frames. Other faults invalidate buffered frames.
                    if(readError!=null && readError!="child_eof") throw new ProbeException(readError);
                    if(frames.Count>0) return frames.Dequeue();
                    if(readError!=null) throw new ProbeException(readError);
                    if(stopping) throw new ProbeException("child_stopped");
                    int left=Left(clock,timeoutMs);
                    if(left==0) throw new ProbeException("read_timeout");
                    Monitor.Wait(state,left);
                }
            }
        }

        void ReadFailure(string reason) { lock(state) { if(readError==null) readError=reason; Monitor.PulseAll(state); } }
        void ReadWorker()
        {
            try
            {
                byte[] chunk=new byte[4096], frame=new byte[FrameLimit]; int length=0;
                while(true)
                {
                    uint read;
                    if(!Native.ReadFile(stdoutRead,chunk,(uint)chunk.Length,out read,IntPtr.Zero) || read==0)
                    { ReadFailure(length==0 ? "child_eof" : "truncated_frame"); return; }
                    for(int i=0;i<read;i++)
                    {
                        if(chunk[i]==10)
                        {
                            int count=length>0 && frame[length-1]==13 ? length-1 : length;
                            string value;
                            try { value=utf8.GetString(frame,0,count); } catch(DecoderFallbackException) { ReadFailure("invalid_utf8"); return; }
                            length=0;
                            lock(state)
                            {
                                if(stopping) return;
                                if(frames.Count>=QueueLimit) { readError="read_queue_overflow"; Monitor.PulseAll(state); return; }
                                frames.Enqueue(value); Monitor.PulseAll(state);
                            }
                        }
                        else { if(length==FrameLimit) { ReadFailure("frame_too_large"); return; } frame[length++]=chunk[i]; }
                    }
                }
            }
            catch { ReadFailure("read_failed"); }
            finally { GC.KeepAlive(this); }
        }
        void WriteWorker()
        {
            try
            {
                while(true)
                {
                    writerWake.WaitOne(); WriteRequest request;
                    lock(state) { if(stopping) return; request=pending; pending=null; }
                    if(request==null) continue;
                    string failure=null;
                    try
                    {
                        uint written;
                        if(!Native.WriteFile(stdinWrite,request.Bytes,(uint)request.Bytes.Length,out written,IntPtr.Zero) || written!=request.Bytes.Length) failure="write_failed";
                    }
                    catch { failure="write_failed"; }
                    lock(state) { request.Error=failure; request.Done=true; if(failure!=null) poisoned=true; Monitor.PulseAll(state); }
                }
            }
            finally { GC.KeepAlive(this); }
        }

        public CleanupReceipt Stop(ProcessIdentity expectedIdentity,int timeoutMs)
        {
            // Reference equality compares the full unforgeable per-launch capability, never the PID.
            if(!Object.ReferenceEquals(expectedIdentity,Identity) || expectedIdentity==null) throw new ProbeException("identity_mismatch");
            ValidateTimeout(timeoutMs); var clock=Stopwatch.StartNew();
            if(!Monitor.TryEnter(stopGate,timeoutMs)) throw new ProbeException("cleanup_busy");
            try
            {
                if(receipt!=null && receipt.Confirmed) return receipt;
                lock(state) { stopping=true; poisoned=true; Monitor.PulseAll(state); }
                writerWake.Set();
                if(!Native.TerminateJobObject(job,1)) throw new ProbeException("job_termination_failed");
                bool reaped=Native.WaitForSingleObject(process,(uint)Left(clock,timeoutMs))==0;
                bool empty=false;
                do
                {
                    Native.JobAccounting info;
                    if(!Native.QueryInformationJobObject(job,1,out info,(uint)Marshal.SizeOf(typeof(Native.JobAccounting)),IntPtr.Zero)) break;
                    if(info.ActiveProcesses==0) { empty=true; break; }
                    int left=Left(clock,timeoutMs); if(left==0) break; Thread.Sleep(Math.Min(10,left));
                } while(true);
                bool readerDone=reader==null || reader.Join(Left(clock,timeoutMs));
                bool writerDone=writer==null || writer.Join(Left(clock,timeoutMs));
                receipt=new CleanupReceipt(reaped,empty,readerDone,writerDone);
                if(receipt.Confirmed) { CloseOwnedHandles(); writerWake.Dispose(); GC.SuppressFinalize(this); }
                return receipt;
            }
            finally { Monitor.Exit(stopGate); }
        }
        public void Dispose()
        {
            // Failure is not converted into a successful receipt. The caller must inspect explicit Stop.
            try { if(Identity!=null) Stop(Identity,5000); } catch(ProbeException) { }
        }
        void CloseOwnedHandles() { Close(ref job); Close(ref process); Close(ref stdinWrite); Close(ref stdoutRead); }
        static void Close(ref IntPtr h) { if(h!=IntPtr.Zero) { Native.CloseHandle(h); h=IntPtr.Zero; } }
        // Active workers keep the owner alive through their last resource access.
        // Failed Start has no caller-owned instance; finalization releases its retained
        // resources after workers exit, without claiming cleanup was confirmed.
        ~OwnedStdioChild() { CloseOwnedHandles(); writerWake.Dispose(); }

        static class Native
        {
            [StructLayout(LayoutKind.Sequential)] internal struct SecurityAttributes { internal int Length; internal IntPtr Descriptor; internal int InheritHandle; }
            [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] internal struct StartupInfo { internal int Size; internal string Reserved; internal string Desktop; internal string Title; internal uint X,Y,XSize,YSize,XCountChars,YCountChars,FillAttribute,Flags; internal ushort ShowWindow,Reserved2; internal IntPtr Reserved2Pointer,StdInput,StdOutput,StdError; }
            [StructLayout(LayoutKind.Sequential)] internal struct StartupInfoEx { internal StartupInfo StartupInfo; internal IntPtr AttributeList; }
            [StructLayout(LayoutKind.Sequential)] internal struct ProcessInformation { internal IntPtr Process,Thread; internal uint ProcessId,ThreadId; }
            [StructLayout(LayoutKind.Sequential)] internal struct BasicLimits { internal long PerProcessUserTimeLimit,PerJobUserTimeLimit; internal uint LimitFlags; internal UIntPtr MinimumWorkingSetSize,MaximumWorkingSetSize; internal uint ActiveProcessLimit; internal UIntPtr Affinity; internal uint PriorityClass,SchedulingClass; }
            [StructLayout(LayoutKind.Sequential)] internal struct IoCounters { internal ulong ReadOperationCount,WriteOperationCount,OtherOperationCount,ReadTransferCount,WriteTransferCount,OtherTransferCount; }
            [StructLayout(LayoutKind.Sequential)] internal struct JobExtendedLimits { internal BasicLimits BasicLimitInformation; internal IoCounters IoInfo; internal UIntPtr ProcessMemoryLimit,JobMemoryLimit,PeakProcessMemoryUsed,PeakJobMemoryUsed; }
            [StructLayout(LayoutKind.Sequential)] internal struct JobAccounting { internal long TotalUserTime,TotalKernelTime,ThisPeriodTotalUserTime,ThisPeriodTotalKernelTime; internal uint TotalPageFaultCount,TotalProcesses,ActiveProcesses,TotalTerminatedProcesses; }
            [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] internal static extern IntPtr CreateJobObject(IntPtr attributes,string name);
            [DllImport("kernel32.dll",SetLastError=true)] internal static extern bool SetInformationJobObject(IntPtr job,int cls,ref JobExtendedLimits info,uint size);
            [DllImport("kernel32.dll",SetLastError=true)] internal static extern bool QueryInformationJobObject(IntPtr job,int cls,out JobAccounting info,uint size,IntPtr returned);
            [DllImport("kernel32.dll",SetLastError=true)] internal static extern bool TerminateJobObject(IntPtr job,uint code);
            [DllImport("kernel32.dll",SetLastError=true)] internal static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
            [DllImport("kernel32.dll",SetLastError=true)] internal static extern bool CreatePipe(out IntPtr read,out IntPtr write,ref SecurityAttributes sa,uint size);
            [DllImport("kernel32.dll",SetLastError=true)] internal static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
            [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] internal static extern IntPtr CreateFile(string name,uint access,uint sharing,ref SecurityAttributes sa,uint creation,uint flags,IntPtr template);
            [DllImport("kernel32.dll",SetLastError=true)] internal static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,uint flags,ref IntPtr size);
            [DllImport("kernel32.dll",SetLastError=true)] internal static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returned);
            [DllImport("kernel32.dll")] internal static extern void DeleteProcThreadAttributeList(IntPtr list);
            [DllImport("kernel32.dll",EntryPoint="CreateProcessW",CharSet=CharSet.Unicode,SetLastError=true)] internal static extern bool CreateProcess(string application,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inherit,uint flags,IntPtr environment,string cwd,ref StartupInfoEx startup,out ProcessInformation process);
            [DllImport("kernel32.dll",SetLastError=true)] internal static extern uint ResumeThread(IntPtr thread);
            [DllImport("kernel32.dll",SetLastError=true)] internal static extern bool TerminateProcess(IntPtr process,uint code);
            [DllImport("kernel32.dll",SetLastError=true)] internal static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
            [DllImport("kernel32.dll",SetLastError=true)] internal static extern bool CloseHandle(IntPtr handle);
            [DllImport("kernel32.dll",SetLastError=true)] internal static extern bool ReadFile(IntPtr handle,byte[] buffer,uint count,out uint read,IntPtr overlapped);
            [DllImport("kernel32.dll",SetLastError=true)] internal static extern bool WriteFile(IntPtr handle,byte[] buffer,uint count,out uint written,IntPtr overlapped);
        }
    }
}
