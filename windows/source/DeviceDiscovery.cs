using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace NetScope {
 public sealed class DiscoveryResult {
  public DateTime At{get;set;} public string Scope{get;set;}
  public int Attempted{get;set;} public int Replied{get;set;} public int Skipped{get;set;}
  public double ElapsedSeconds{get;set;} public bool Cancelled{get;set;} public bool DeadlineReached{get;set;}
  public string Error{get;set;} public string Note{get;set;}
  public List<string> RepliedAddresses{get;set;} public List<DeviceInfo> Devices{get;set;}
  public DiscoveryResult(){At=DateTime.UtcNow;Scope="未开始";Error="";RepliedAddresses=new List<string>();Devices=new List<DeviceInfo>();
   Note="仅检查明确选中连接的有限IPv4范围；回应表示本次收到ICMP，不回应仍未知。不是完整Wi-Fi/公司设备清单，不检测端口、名称或主人。";}
 }
 internal sealed class DiscoveryPlan {
  internal string AdapterId,AdapterName,Scope;internal int InterfaceIndex;
  internal IPAddress LocalAddress;internal List<IPAddress> Targets=new List<IPAddress>();
 }
 internal enum DiscoveryProbeOutcome { Skipped, NoReply, Replied }

 public static class DeviceDiscovery {
  static readonly SemaphoreSlim BatchGate=new SemaphoreSlim(1,1),NativeSlots=new SemaphoreSlim(8,8);
  const int MaximumMilliseconds=20000;
  static readonly DiscoveryCacheReader SharedCache=new DiscoveryCacheReader(()=>new NetworkCollector().GetNeighborsAsync());
  public static async Task<DiscoveryResult> DiscoverAsync(string selectedAdapterId,CancellationToken cancellationToken){
   var wall=Stopwatch.StartNew();var result=new DiscoveryResult();
   if(!await BatchGate.WaitAsync(0).ConfigureAwait(false)){result.Error="已有设备查找正在进行，本次未发送请求。";return result;}
   try {
    if(cancellationToken.IsCancellationRequested){result.Cancelled=true;return result;}
    DiscoveryPlan plan=BuildPlan(selectedAdapterId);result.Scope=plan.Scope;
    var before=await ReadCacheWithinAsync(wall,cancellationToken).ConfigureAwait(false);
    var runner=new DiscoveryRunner(
     address=>RouteUsesInterface(address,plan.InterfaceIndex),
     (address,timeout,token,sent)=>ProbeAsync(address,plan.InterfaceIndex,timeout,token,sent),
     token=>ReadCacheWithinAsync(wall,token),MaximumMilliseconds);
    return await runner.RunAsync(plan,before,wall,cancellationToken).ConfigureAwait(false);
   }catch(OperationCanceledException){result.Cancelled=true;return result;}
   catch(Exception ex){result.Error="本次没有开始或完成有效查找："+ex.Message;return result;}
   finally{result.ElapsedSeconds=wall.Elapsed.TotalSeconds;BatchGate.Release();}
  }
  static DiscoveryPlan BuildPlan(string adapterId){
   if(String.IsNullOrWhiteSpace(adapterId)||adapterId=="auto")throw new ArgumentException("请明确选择一张已连接的物理Wi-Fi或有线网卡。");
   var nic=NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(x=>x.Id==adapterId);
   if(nic==null||nic.OperationalStatus!=OperationalStatus.Up||NetworkCollector.IsProbablyVirtual(nic)||
      !DiscoveryPlanning.IsPhysicalType(nic.NetworkInterfaceType))throw new ArgumentException("所选接口不是已连接的物理Wi-Fi/有线连接。");
   var properties=nic.GetIPProperties();var ipv4=properties.GetIPv4Properties();
   if(ipv4==null)throw new ArgumentException("所选连接没有IPv4接口索引。");
   var address=properties.UnicastAddresses.FirstOrDefault(x=>DiscoveryPlanning.IsPrivateIPv4(x.Address)&&x.IPv4Mask!=null);
   if(address==null)throw new ArgumentException("所选连接没有RFC1918私有IPv4地址，不进行发现。");
   var targets=DiscoveryPlanning.Targets(address.Address,address.IPv4Mask);
   var own=new HashSet<string>(properties.UnicastAddresses.Select(x=>x.Address.ToString()));
   targets.RemoveAll(x=>own.Contains(x.ToString()));
   if(targets.Count==0)throw new ArgumentException("所选地址的实际子网内没有可检查的其他地址。");
   string scope=nic.Name+" · "+DiscoveryPlanning.Scope(address.Address,address.IPv4Mask)+
    " · 仅此地址所在子网与/24的交集，最多"+targets.Count+"个地址；逐目标核对路由，最多20秒";
   return new DiscoveryPlan{AdapterId=nic.Id,AdapterName=nic.Name,InterfaceIndex=ipv4.Index,
    LocalAddress=address.Address,Targets=targets,Scope=scope};
  }
  static Task<List<DeviceInfo>> ReadCacheWithinAsync(Stopwatch wall,CancellationToken token){
   int remaining=MaximumMilliseconds-(int)wall.ElapsedMilliseconds;
   return SharedCache.ReadAsync(Math.Max(0,remaining),token);
  }
  static bool RouteUsesInterface(IPAddress address,int expected){
   if(address.AddressFamily!=AddressFamily.InterNetwork)return false;
   uint index;try{return GetBestInterface(BitConverter.ToUInt32(address.GetAddressBytes(),0),out index)==0&&index==(uint)expected;}catch{return false;}
  }
  // Slots remain owned until the native operation really completes, even if the
  // caller's deadline wins. This bounds repeated clicks to eight native requests.
  static async Task<DiscoveryProbeOutcome> ProbeAsync(IPAddress address,int expectedIndex,int timeout,CancellationToken token,Action onSent){
   bool slot=false,transferred=false;Ping ping=null;
   try {
    slot=await NativeSlots.WaitAsync(timeout,token).ConfigureAwait(false);
    if(!slot||token.IsCancellationRequested||!RouteUsesInterface(address,expectedIndex))return DiscoveryProbeOutcome.Skipped;
    ping=new Ping();Ping owned=ping;
    token.ThrowIfCancellationRequested();
    Task<PingReply> work=ping.SendPingAsync(address,timeout,new byte[8],new PingOptions(1,true));
    // This callback runs only after a real SendPingAsync request was accepted.
    // Waiting for a native slot or rejecting a changed route never counts.
    onSent();
    transferred=true;
    work.ContinueWith(t=>{if(t.IsFaulted){var observed=t.Exception;}try{owned.Dispose();}catch{}NativeSlots.Release();},
     CancellationToken.None,TaskContinuationOptions.ExecuteSynchronously,TaskScheduler.Default);
    using(token.Register(()=>ThreadPool.QueueUserWorkItem(_=>{try{owned.SendAsyncCancel();}catch{}})))
    using(var deadline=CancellationTokenSource.CreateLinkedTokenSource(token)){
     if(await Task.WhenAny(work,Task.Delay(timeout+50,deadline.Token)).ConfigureAwait(false)!=work){
      ThreadPool.QueueUserWorkItem(_=>{try{owned.SendAsyncCancel();}catch{}});
      return DiscoveryProbeOutcome.NoReply;
     }
     deadline.Cancel();
     try{var reply=await work.ConfigureAwait(false);return reply.Status==IPStatus.Success&&reply.Address!=null&&reply.Address.Equals(address)?
       DiscoveryProbeOutcome.Replied:DiscoveryProbeOutcome.NoReply;}catch{return DiscoveryProbeOutcome.NoReply;}
    }
   }catch(OperationCanceledException){return transferred?DiscoveryProbeOutcome.NoReply:DiscoveryProbeOutcome.Skipped;}
   catch{return transferred?DiscoveryProbeOutcome.NoReply:DiscoveryProbeOutcome.Skipped;}
   finally{if(!transferred){if(ping!=null)ping.Dispose();if(slot)NativeSlots.Release();}}
  }
  [DllImport("iphlpapi.dll")]static extern uint GetBestInterface(uint destination,out uint bestInterface);
 }

 internal static class DiscoveryPlanning {
  internal static bool IsPhysicalType(NetworkInterfaceType type){return type==NetworkInterfaceType.Ethernet||
   type==NetworkInterfaceType.Wireless80211||type==NetworkInterfaceType.FastEthernetT||
   type==NetworkInterfaceType.FastEthernetFx||type==NetworkInterfaceType.GigabitEthernet;}
  internal static bool IsPrivateIPv4(IPAddress address){
   if(address==null||address.AddressFamily!=AddressFamily.InterNetwork)return false;
   byte[] b=address.GetAddressBytes();return b[0]==10||(b[0]==172&&b[1]>=16&&b[1]<=31)||(b[0]==192&&b[1]==168);
  }
  static uint Number(IPAddress address){byte[] b=address.GetAddressBytes();return ((uint)b[0]<<24)|((uint)b[1]<<16)|((uint)b[2]<<8)|b[3];}
  static IPAddress Address(uint value){return new IPAddress(new[]{(byte)(value>>24),(byte)(value>>16),(byte)(value>>8),(byte)value});}
  static uint EffectiveMask(IPAddress local,IPAddress mask){
   if(!IsPrivateIPv4(local)||mask==null||mask.AddressFamily!=AddressFamily.InterNetwork)throw new ArgumentException("仅接受私有IPv4和有效子网掩码。");
   uint bits=Number(mask),inverse=~bits;
   if(bits==0||(inverse&(inverse+1))!=0)throw new ArgumentException("子网掩码无效。");
   return bits|0xffffff00u;
  }
  internal static List<IPAddress> Targets(IPAddress local,IPAddress mask){
   uint effective=EffectiveMask(local,mask),own=Number(local),network=own&effective,broadcast=network|~effective;
   var list=new List<IPAddress>();
   for(uint value=network+1;value<broadcast&&list.Count<254;value++)if(value!=own)list.Add(Address(value));
   return list;
  }
  internal static string Scope(IPAddress local,IPAddress mask){
   uint effective=EffectiveMask(local,mask),value=effective;int prefix=0;
   while((value&0x80000000u)!=0){prefix++;value<<=1;}
   return Address(Number(local)&effective)+"/"+prefix;
  }
  internal static bool ValidUnicastMac(string mac){
   string raw=(mac??"").Replace("-","").Replace(":","");
   if(raw.Length!=12||!raw.All(c=>Uri.IsHexDigit(c)))return false;
   if(raw=="000000000000"||raw.Equals("FFFFFFFFFFFF",StringComparison.OrdinalIgnoreCase))return false;
   return (Convert.ToByte(raw.Substring(0,2),16)&1)==0;
  }
}

 internal sealed class DiscoveryRunner {
  readonly Func<IPAddress,bool> route;
  readonly Func<IPAddress,int,CancellationToken,Action,Task<DiscoveryProbeOutcome>> probe;
  readonly Func<CancellationToken,Task<List<DeviceInfo>>> cache;
  readonly int maximumMilliseconds;
  internal DiscoveryRunner(Func<IPAddress,bool> route,Func<IPAddress,int,CancellationToken,Action,Task<DiscoveryProbeOutcome>> probe,
   Func<CancellationToken,Task<List<DeviceInfo>>> cache,int maximumMilliseconds){
   this.route=route;this.probe=probe;this.cache=cache;this.maximumMilliseconds=Math.Max(1,Math.Min(20000,maximumMilliseconds));
  }
  internal async Task<DiscoveryResult> RunAsync(DiscoveryPlan plan,List<DeviceInfo> before,Stopwatch wall,CancellationToken cancellation){
   var result=new DiscoveryResult{Scope=plan.Scope};var replies=new HashSet<string>();object gate=new object();
   int next=-1,attempted=0,stopLaunching=0;string executionNote="";
   int remaining=maximumMilliseconds-(int)wall.ElapsedMilliseconds;
   if(remaining<=0||cancellation.IsCancellationRequested){
    result.Cancelled=cancellation.IsCancellationRequested;result.DeadlineReached=remaining<=0;
    result.Skipped=plan.Targets.Count;result.Devices=(before??new List<DeviceInfo>()).Select(DeviceNameResolver.Clone).ToList();
    result.ElapsedSeconds=wall.Elapsed.TotalSeconds;return result;
   }
   using(var overall=CancellationTokenSource.CreateLinkedTokenSource(cancellation)){
    overall.CancelAfter(remaining);
    Func<Task> worker=async()=>{
     while(!overall.IsCancellationRequested&&Interlocked.CompareExchange(ref stopLaunching,0,0)==0){
      int position=Interlocked.Increment(ref next);if(position>=plan.Targets.Count)return;
      IPAddress address=plan.Targets[position];bool allowed=false;
      try{allowed=route(address);}catch{}
      if(!allowed)continue;
      int left=maximumMilliseconds-(int)wall.ElapsedMilliseconds;
      // Leave a small margin for cancellation and the final passive cache read.
      if(left<=100)return;
      int timeout=Math.Min(500,Math.Max(1,left-100));
      using(var single=CancellationTokenSource.CreateLinkedTokenSource(overall.Token)){
       int sent=0;Task<DiscoveryProbeOutcome> operation=null;
       Action onSent=()=>{if(Interlocked.Exchange(ref sent,1)==0)Interlocked.Increment(ref attempted);};
       try{
        operation=probe(address,timeout,single.Token,onSent);
        if(operation==null)continue;
        Task deadline=Task.Delay(Math.Min(left,timeout+100),single.Token);
        if(await Task.WhenAny(operation,deadline).ConfigureAwait(false)!=operation){
         single.Cancel();Interlocked.Exchange(ref stopLaunching,1);
         operation.ContinueWith(t=>{if(t.IsFaulted){var observed=t.Exception;}},TaskScheduler.Default);
         if(!overall.IsCancellationRequested)lock(gate)executionNote="ICMP操作未在预算内完成，已停止后续请求；未回应仍未知。";
         return;
        }
        var outcome=await operation.ConfigureAwait(false);
        single.Cancel();
        if(outcome==DiscoveryProbeOutcome.Replied&&Interlocked.CompareExchange(ref sent,0,0)==1)lock(gate)replies.Add(address.ToString());
       }catch(OperationCanceledException){return;}
       catch{lock(gate)executionNote="部分ICMP请求未完成；没有把未回应视为设备不存在。";}
      }
     }
    };
    var workers=new List<Task>();
    for(int index=0;index<Math.Min(8,plan.Targets.Count);index++)workers.Add(Task.Run(worker));
    Task all=Task.WhenAll(workers);
    int wait=Math.Max(1,maximumMilliseconds-(int)wall.ElapsedMilliseconds);
    if(await Task.WhenAny(all,Task.Delay(wait,overall.Token)).ConfigureAwait(false)!=all){
     overall.Cancel();
     all.ContinueWith(t=>{if(t.IsFaulted){var observed=t.Exception;}},TaskScheduler.Default);
    }else await all.ConfigureAwait(false);
    List<DeviceInfo> after=new List<DeviceInfo>();
    if(!overall.IsCancellationRequested&&wall.ElapsedMilliseconds<maximumMilliseconds){
     try{
      Task<List<DeviceInfo>> read=cache(overall.Token);
      int budget=Math.Max(1,maximumMilliseconds-(int)wall.ElapsedMilliseconds);
      if(await Task.WhenAny(read,Task.Delay(budget,overall.Token)).ConfigureAwait(false)==read)after=await read.ConfigureAwait(false);
      else read.ContinueWith(t=>{if(t.IsFaulted){var observed=t.Exception;}},TaskScheduler.Default);
     }catch{executionNote+=" 被动缓存刷新未完成，仍保留先前记录与本次回应。";}
    }
    lock(gate){result.RepliedAddresses=replies.OrderBy(x=>x,StringComparer.Ordinal).ToList();result.Error=executionNote;}
    result.Attempted=Math.Max(0,Math.Min(plan.Targets.Count,Interlocked.CompareExchange(ref attempted,0,0)));
    result.Replied=result.RepliedAddresses.Count;result.Skipped=plan.Targets.Count-result.Attempted;
    result.Cancelled=cancellation.IsCancellationRequested;
    result.DeadlineReached=wall.ElapsedMilliseconds>=maximumMilliseconds||(!result.Cancelled&&overall.IsCancellationRequested);
    result.Devices=MergeDevices(plan,before,after,result.RepliedAddresses,result.At);
    result.ElapsedSeconds=wall.Elapsed.TotalSeconds;
    overall.Cancel();return result;
   }
  }
  internal static List<DeviceInfo> MergeDevices(DiscoveryPlan plan,IEnumerable<DeviceInfo> before,IEnumerable<DeviceInfo> after,
   IEnumerable<string> replies,DateTime at){
   var known=(before??new DeviceInfo[0]).Where(x=>x!=null).Select(DeviceNameResolver.Clone).ToList();
   var allowed=new HashSet<string>(plan.Targets.Select(x=>x.ToString()),StringComparer.Ordinal);
   var replied=new HashSet<string>(replies??new string[0],StringComparer.Ordinal);
   Func<DeviceInfo,bool> inInterface=d=>{
    var match=System.Text.RegularExpressions.Regex.Match(d.Source??"",@".*接口\s+([0-9]+)");
    int index;return match.Success&&Int32.TryParse(match.Groups[1].Value,out index)&&index==plan.InterfaceIndex;
   };
   foreach(var fresh in (after??new DeviceInfo[0]).Where(x=>x!=null)){
    if(!allowed.Contains(fresh.Ip??"")||!inInterface(fresh))continue;
    if(!replied.Contains(fresh.Ip??"")&&!DiscoveryPlanning.ValidUnicastMac(fresh.Mac))continue;
    var current=DeviceNameResolver.Clone(fresh);
    int index=known.FindIndex(x=>x.Ip==current.Ip&&x.Source==current.Source);
    if(index>=0){
     var prior=known[index];
     bool sameMac=DiscoveryPlanning.ValidUnicastMac(prior.Mac)&&DiscoveryPlanning.ValidUnicastMac(current.Mac)&&
      prior.Mac.Replace(":","").Replace("-","").Equals(current.Mac.Replace(":","").Replace("-",""),StringComparison.OrdinalIgnoreCase);
     if(sameMac&&(!String.IsNullOrWhiteSpace(prior.ReportedNameSource)||!String.IsNullOrWhiteSpace(prior.NameSource))){
      current.Name=prior.Name;current.NameSource=prior.NameSource;current.ReportedName=prior.ReportedName;
      current.ReportedNameSource=prior.ReportedNameSource;current.Hint=prior.Hint;current.ReportedHint=prior.ReportedHint;
     }
     known[index]=current;
    }else known.Add(current);
   }
   foreach(string ip in replied.Where(allowed.Contains)){
    var current=known.FirstOrDefault(x=>x.Ip==ip&&inInterface(x));
    if(current==null){
     current=new DeviceInfo{Ip=ip,Mac="未知",Name="未知",ReportedName="未知",NameSource="未识别",
      Hint="仅确认本次ICMP回应；设备类型、名称和主人仍未知；未探测端口",
      Source="用户触发的有限 ICMP 回应；接口 "+plan.InterfaceIndex,ObservedAt=at};
     known.Add(current);
    }
    current.State=(String.IsNullOrEmpty(current.State)?"":current.State+"；")+"本次ICMP回应（不代表主人已确认）";
    current.ObservedAt=at;
   }
   return known;
  }
 }

 // A cancelled waiter must not release ownership of an unfinished system cache
 // read. All batches reuse this one operation until the actual read completes.
 internal sealed class DiscoveryCacheReader {
  readonly object gate=new object();readonly Func<Task<List<DeviceInfo>>> read;
  Task<List<DeviceInfo>> inFlight;
  internal DiscoveryCacheReader(Func<Task<List<DeviceInfo>>> read){this.read=read;}
  internal async Task<List<DeviceInfo>> ReadAsync(int milliseconds,CancellationToken token){
   if(milliseconds<=0||token.IsCancellationRequested)return new List<DeviceInfo>();
   Task<List<DeviceInfo>> work;
   lock(gate){
    if(inFlight==null){
     work=read()??Task.FromResult(new List<DeviceInfo>());inFlight=work;
     work.ContinueWith(t=>{if(t.IsFaulted){var observed=t.Exception;}lock(gate){if(Object.ReferenceEquals(inFlight,t))inFlight=null;}},
      CancellationToken.None,TaskContinuationOptions.ExecuteSynchronously,TaskScheduler.Default);
    }else work=inFlight;
   }
   using(var deadline=CancellationTokenSource.CreateLinkedTokenSource(token)){
    if(await Task.WhenAny(work,Task.Delay(milliseconds,deadline.Token)).ConfigureAwait(false)!=work)return new List<DeviceInfo>();
    deadline.Cancel();return await work.ConfigureAwait(false);
   }
  }
 }
}
