using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Parsers;
using Microsoft.Diagnostics.Tracing.Session;

namespace NetScope {
 public class ProcessTrafficRow {
  public int Pid{get;set;} public string Name{get;set;} public string InstanceId{get;set;}
  public long ReceivedBytes{get;set;} public long SentBytes{get;set;}
  public long CumulativeReceivedBytes{get;set;} public long CumulativeSentBytes{get;set;}
  public double DownloadBps{get;set;} public double UploadBps{get;set;} public double ObservedSharePercent{get;set;} public string Note{get;set;}
 }
 public class ProcessTrafficSnapshot {
  public DateTime At{get;set;} public DateTime WindowStart{get;set;} public double IntervalSeconds{get;set;}
  public string State{get;set;} public string Error{get;set;} public string InstanceId{get;set;}
  public long LostEvents{get;set;} public long LostEventsInWindow{get;set;} public bool IsPartial{get;set;}
  public long EventCount{get;set;} public long CumulativeReceivedBytes{get;set;} public long CumulativeSentBytes{get;set;}
  public long EvictedProcessRecords{get;set;} public int HelperPid{get;set;} public int ParentPid{get;set;}
  public string Measurement{get;set;} public List<ProcessTrafficRow> Processes{get;set;}
  public ProcessTrafficSnapshot(){At=DateTime.UtcNow;Processes=new List<ProcessTrafficRow>();}
 }
 public static class ProcessTrafficCollector {
  public const string Measurement="观测进程事件字节占比，非物理线路占比。仅累计 TCP/UDP IPv4/IPv6 Send/Recv 的 PID 与 size；不读取通信内容、地址、端口或命令行。VPN、代理和应用可能在不同层重复计量，不能将这些字节当作网卡流量相加。ETW 缓冲会造成显示延迟；丢事件或采样漏读时统计不完整。速率按实际事件交付采样窗口计算。";
  public static void Run(string outputPath,int parentPid){
   string path=Path.GetFullPath(outputPath);string directory=Path.GetDirectoryName(path);
   if(String.IsNullOrWhiteSpace(directory)||!String.Equals(Path.GetExtension(path),".json",StringComparison.OrdinalIgnoreCase))throw new ArgumentException("实时快照须为本地 JSON 文件路径");
   Directory.CreateDirectory(directory);
   int ownPid;using(Process self=Process.GetCurrentProcess())ownPid=self.Id;
   string sessionName="NetScope-"+parentPid+"-"+ownPid;
   string instance=sessionName+"-"+Guid.NewGuid().ToString("N");
   var initial=Status("Starting",null,instance,ownPid,parentPid);
   WriteAtomic(path,initial);
   // No automatic elevation. Only the UI's user action may launch this helper via UAC.
   if(TraceEventSession.IsElevated()!=true){WriteAtomic(path,Status("PermissionRequired","需要用户在界面主动启用管理员进程流量采集；当前没有创建 ETW 会话。",instance,ownPid,parentPid));return;}
   Version os=Environment.OSVersion.Version;
   if(os.Major<6||(os.Major==6&&os.Minor<2)){WriteAtomic(path,Status("Error","具名独立内核会话需要 Windows 8 或更新版本；未启用旧式全局 NT Kernel Logger。",instance,ownPid,parentPid));return;}
   Process parent=null;TraceEventSession session=null;Thread reader=null;
   var stop=new ManualResetEvent(false);var readerDone=new ManualResetEvent(false);
   string readerError=null;string finalState="Stopped",finalError=null;int cleanupDone=0;
   var accumulator=new TrafficAccumulator(instance,ownPid,parentPid);
   Action cleanup=delegate{if(Interlocked.Exchange(ref cleanupDone,1)==0&&session!=null){try{session.Dispose();}catch{}}};
   EventHandler exitHandler=delegate{stop.Set();cleanup();};
   UnhandledExceptionEventHandler crashHandler=delegate{stop.Set();cleanup();};
   ConsoleCancelEventHandler cancelHandler=delegate(object sender,ConsoleCancelEventArgs e){e.Cancel=true;stop.Set();};
   try{
    if(parentPid<=0)throw new ArgumentException("必须提供有效父进程 PID");
    parent=Process.GetProcessById(parentPid);if(parent.Handle==IntPtr.Zero)throw new InvalidOperationException("无法持有父进程句柄");if(parent.HasExited){WriteAtomic(path,Status("Stopped","父进程已退出",instance,ownPid,parentPid));return;}
    if(File.Exists(path+".stop")){WriteAtomic(path,Status("Stopped","已收到停止标记",instance,ownPid,parentPid));return;}
    // Never restart or stop a session created by another process.
    if(TraceEventSession.GetActiveSessionNames().Any(x=>String.Equals(x,sessionName,StringComparison.Ordinal)))throw new InvalidOperationException("同名 ETW 会话已经存在；未覆盖该会话");
    AppDomain.CurrentDomain.ProcessExit+=exitHandler;AppDomain.CurrentDomain.UnhandledException+=crashHandler;
    try{Console.CancelKeyPress+=cancelHandler;}catch{}
    accumulator.SeedProcesses();
    session=new TraceEventSession(sessionName);session.StopOnDispose=true;session.BufferSizeMB=32;
    // The library additionally enables process/thread metadata required by its
    // kernel parser. Only process name/lifetime callbacks below are consumed.
    session.EnableKernelProvider(KernelTraceEventParser.Keywords.NetworkTCPIP|KernelTraceEventParser.Keywords.Process);
    ETWTraceEventSource source=session.Source;
    // Disable unbounded parser name/thread caches. Network event PID is decoded
    // from the provider's own PID field, not guessed from the current CPU thread.
    var kernel=new KernelTraceEventParser(source,KernelTraceEventParser.ParserTrackingOptions.None);
    kernel.TcpIpSend+=d=>accumulator.Add(d.ProcessID,d.size,true,d.TimeStamp.ToUniversalTime());
    kernel.TcpIpRecv+=d=>accumulator.Add(d.ProcessID,d.size,false,d.TimeStamp.ToUniversalTime());
    kernel.TcpIpSendIPV6+=d=>accumulator.Add(d.ProcessID,d.size,true,d.TimeStamp.ToUniversalTime());
    kernel.TcpIpRecvIPV6+=d=>accumulator.Add(d.ProcessID,d.size,false,d.TimeStamp.ToUniversalTime());
    kernel.UdpIpSend+=d=>accumulator.Add(d.ProcessID,d.size,true,d.TimeStamp.ToUniversalTime());
    kernel.UdpIpRecv+=d=>accumulator.Add(d.ProcessID,d.size,false,d.TimeStamp.ToUniversalTime());
    kernel.UdpIpSendIPV6+=d=>accumulator.Add(d.ProcessID,d.size,true,d.TimeStamp.ToUniversalTime());
    kernel.UdpIpRecvIPV6+=d=>accumulator.Add(d.ProcessID,d.size,false,d.TimeStamp.ToUniversalTime());
    kernel.ProcessStart+=d=>accumulator.Started(d.ProcessID,d.ImageFileName,d.TimeStamp.ToUniversalTime());
    kernel.ProcessStop+=d=>accumulator.Exited(d.ProcessID,d.TimeStamp.ToUniversalTime());
    reader=new Thread(delegate(){try{source.Process();}catch(Exception ex){readerError=SafeError(ex);}finally{readerDone.Set();}});reader.IsBackground=true;reader.Name="NetScope ETW network reader";reader.Start();
    while(!stop.WaitOne(2000)){
     if(File.Exists(path+".stop")){finalError="用户停止采集";break;}
     bool parentAlive;try{parentAlive=!parent.HasExited;}catch{parentAlive=false;}
     if(!parentAlive){finalError="父进程退出，已停止采集";break;}
     if(readerDone.WaitOne(0)){finalState="Error";finalError=readerError??"ETW 实时读取已意外结束";break;}
     long lost=0;bool lossKnown=true;try{lost=unchecked((uint)session.EventsLost);}catch{lossKnown=false;}
     accumulator.ResolveUnknownNames();
     var snapshot=accumulator.TakeSnapshot(lost,lossKnown,"Running",lossKnown?null:"暂时无法读取 ETW 丢事件计数，完整性未知");
     WriteAtomic(path,snapshot);
    }
   }catch(UnauthorizedAccessException ex){finalState="PermissionRequired";finalError=SafeError(ex);}
   catch(Exception ex){finalState="Error";finalError=SafeError(ex);}
   finally{
    long finalLost=0;bool lossKnown=false;if(session!=null){try{finalLost=unchecked((uint)session.EventsLost);lossKnown=true;}catch{}}
    cleanup();
    if(reader!=null&&reader.IsAlive){try{reader.Join(3000);}catch{}}
    try{WriteAtomic(path,accumulator.TakeSnapshot(finalLost,lossKnown,finalState,finalError));}catch{}
    AppDomain.CurrentDomain.ProcessExit-=exitHandler;AppDomain.CurrentDomain.UnhandledException-=crashHandler;
    try{Console.CancelKeyPress-=cancelHandler;}catch{}
    if(parent!=null)parent.Dispose();
    // A forced OS kill or power failure cannot execute managed cleanup. Normal
    // UI stop, parent exit and handled errors all dispose this session only.
    if(reader==null||!reader.IsAlive){readerDone.Dispose();stop.Dispose();}
   }
  }
  static ProcessTrafficSnapshot Status(string state,string error,string instance,int ownPid,int parentPid){return new ProcessTrafficSnapshot{State=state,Error=error,InstanceId=instance,HelperPid=ownPid,ParentPid=parentPid,Measurement=Measurement,IsPartial=state!="Running"};}
  static string SafeError(Exception error){if(error is UnauthorizedAccessException)return "没有足够权限创建或读取 ETW 会话";return error.GetType().Name+"："+error.Message;}
  static void WriteAtomic(string path,ProcessTrafficSnapshot snapshot){
   string temp=path+".tmp-"+snapshot.HelperPid;string json=new JavaScriptSerializer{MaxJsonLength=16*1024*1024}.Serialize(snapshot);
   try{
    using(var stream=new FileStream(temp,FileMode.Create,FileAccess.Write,FileShare.None)){byte[] data=new UTF8Encoding(false).GetBytes(json);stream.Write(data,0,data.Length);stream.Flush(true);}
    for(int attempt=0;;attempt++){try{if(File.Exists(path))File.Replace(temp,path,null);else File.Move(temp,path);break;}catch(IOException){if(attempt>=3)throw;Thread.Sleep(40);}}
   }finally{try{if(File.Exists(temp))File.Delete(temp);}catch{}}
  }
  internal sealed class TrafficAccumulator {
   const int MaximumRecords=4096;
   readonly object sync=new object();
   readonly Dictionary<string,Counter> records=new Dictionary<string,Counter>();
   readonly Dictionary<int,Counter> byPid=new Dictionary<int,Counter>();
   readonly string instance;readonly int ownPid,parentPid;
   long totalReceived,totalSent,windowReceived,windowSent,windowEvents,evicted,previousLost;
   long previousTick=Stopwatch.GetTimestamp();DateTime previousAt=DateTime.UtcNow;
   public TrafficAccumulator(string id,int helper,int parent){instance=id;ownPid=helper;parentPid=parent;}
   public void SeedProcesses(){
    try{foreach(Process process in Process.GetProcesses()){using(process){try{int pid=process.Id;string name=process.ProcessName;DateTime started=process.StartTime.ToUniversalTime();lock(sync){if(!byPid.ContainsKey(pid))NewCounter(pid,name,started);}}catch{}}}}catch{}
   }
   public void Started(int pid,string imageName,DateTime time){
    if(pid<0)return;string name=CleanName(imageName);lock(sync){Counter old;if(byPid.TryGetValue(pid,out old))old.Exited=true;NewCounter(pid,name,time);}
   }
   public void Exited(int pid,DateTime time){lock(sync){Counter counter;if(byPid.TryGetValue(pid,out counter)){counter.Exited=true;counter.LastActivity=time;}}}
   public void Add(int pid,long bytes,bool sent,DateTime eventAt){
    if(bytes<=0)return;if(pid<0)pid=0;
    lock(sync){Counter counter;if(!byPid.TryGetValue(pid,out counter))counter=NewCounter(pid,"未知",eventAt);
     if(sent){counter.WindowSent+=bytes;counter.TotalSent+=bytes;windowSent+=bytes;totalSent+=bytes;}
     else{counter.WindowReceived+=bytes;counter.TotalReceived+=bytes;windowReceived+=bytes;totalReceived+=bytes;}
     counter.LastActivity=eventAt;if(counter.FirstNetworkEvent==DateTime.MinValue)counter.FirstNetworkEvent=eventAt;windowEvents++;
    }
   }
   Counter NewCounter(int pid,string name,DateTime started){
    if(records.Count>=MaximumRecords){
     Counter victim=records.Values.OrderBy(x=>x.WindowReceived+x.WindowSent>0?1:0).ThenBy(x=>x.Exited?0:1).ThenBy(x=>x.LastActivity).First();
     records.Remove(victim.Id);Counter current;if(byPid.TryGetValue(victim.Pid,out current)&&Object.ReferenceEquals(current,victim))byPid.Remove(victim.Pid);evicted++;
    }
    string id=instance+"/"+pid+"/"+started.Ticks;
    while(records.ContainsKey(id))id+="x";
    Counter item=new Counter{Pid=pid,Name=CleanName(name),Id=id,Started=started,LastActivity=started};records[id]=item;byPid[pid]=item;return item;
   }
   public void ResolveUnknownNames(){
    List<Counter> unknown;lock(sync){unknown=records.Values.Where(x=>x.Name=="未知"&&x.Pid>0&&!x.Exited&&(x.WindowReceived+x.WindowSent)>0).Take(32).ToList();}
    foreach(Counter counter in unknown){try{using(Process process=Process.GetProcessById(counter.Pid)){
     string name=process.ProcessName;DateTime start=process.StartTime.ToUniversalTime();
     lock(sync){Counter current;if(!byPid.TryGetValue(counter.Pid,out current)||!Object.ReferenceEquals(current,counter))continue;
      if(counter.FirstNetworkEvent!=DateTime.MinValue&&start>counter.FirstNetworkEvent.AddMilliseconds(20)){counter.Note="PID 可能已复用，名称未知";counter.Exited=true;}
      else counter.Name=CleanName(name);
     }
    }}catch{/* An exited or protected process remains explicitly unknown. */}}
   }
   public ProcessTrafficSnapshot TakeSnapshot(long lost,bool lossKnown,string state,string error){lock(sync){
    long tick=Stopwatch.GetTimestamp();DateTime now=DateTime.UtcNow;double seconds=Math.Max(0.001,(tick-previousTick)/(double)Stopwatch.Frequency);
    long bytes=windowReceived+windowSent;
    var snapshot=new ProcessTrafficSnapshot{At=now,WindowStart=previousAt,IntervalSeconds=seconds,State=state,Error=error,InstanceId=instance,HelperPid=ownPid,ParentPid=parentPid,Measurement=Measurement,LostEvents=lost,LostEventsInWindow=Math.Max(0,lost-previousLost),IsPartial=!lossKnown||lost>0||evicted>0,EventCount=windowEvents,CumulativeReceivedBytes=totalReceived,CumulativeSentBytes=totalSent,EvictedProcessRecords=evicted};
    foreach(Counter counter in records.Values){
     long count=counter.WindowReceived+counter.WindowSent;
     if(count>0){string note=counter.Note;if(counter.Name=="未知")note=String.IsNullOrEmpty(note)?"进程名称无法核实（已退出、受保护或无法归属）":note;
      if(IsLikelyProxy(counter.Name))note=String.IsNullOrEmpty(note)?"名称疑似代理/VPN；可能与应用层重复计量":note+"；名称疑似代理/VPN";
      snapshot.Processes.Add(new ProcessTrafficRow{Pid=counter.Pid,Name=counter.Name,InstanceId=counter.Id,ReceivedBytes=counter.WindowReceived,SentBytes=counter.WindowSent,CumulativeReceivedBytes=counter.TotalReceived,CumulativeSentBytes=counter.TotalSent,DownloadBps=counter.WindowReceived/seconds,UploadBps=counter.WindowSent/seconds,ObservedSharePercent=bytes>0?count*100.0/bytes:0,Note=note});
     }
     counter.WindowReceived=0;counter.WindowSent=0;
    }
    snapshot.Processes=snapshot.Processes.OrderByDescending(x=>x.DownloadBps+x.UploadBps).ThenBy(x=>x.Pid).ToList();
    previousTick=tick;previousAt=now;previousLost=lost;windowEvents=0;windowReceived=0;windowSent=0;
    return snapshot;
   }}
   static bool IsLikelyProxy(string name){string value=(name??"").ToLowerInvariant();string[] tokens={"clash","mihomo","v2ray","xray","sing-box","wireguard","openvpn","tailscale","zerotier","shadowsocks","vpn"};return tokens.Any(value.Contains);}
   static string CleanName(string value){if(String.IsNullOrWhiteSpace(value))return "未知";try{value=Path.GetFileName(value);if(value.EndsWith(".exe",StringComparison.OrdinalIgnoreCase))value=value.Substring(0,value.Length-4);}catch{return "未知";}return value.Length>120?value.Substring(0,120):value;}
   sealed class Counter{public int Pid;public string Name,Id,Note;public DateTime Started,LastActivity,FirstNetworkEvent;public bool Exited;public long WindowReceived,WindowSent,TotalReceived,TotalSent;}
  }
 }
}

