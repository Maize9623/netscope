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
using Microsoft.Win32;
namespace NetScope {
public class NetworkCollector {
 readonly object localLock=new object(), dnsLock=new object();
 readonly Dictionary<string,CounterSnapshot> counters=new Dictionary<string,CounterSnapshot>();
 readonly Dictionary<string,Task<IPAddress[]>> dnsInFlight=new Dictionary<string,Task<IPAddress[]>>(StringComparer.OrdinalIgnoreCase);
 readonly SemaphoreSlim probeSlots=new SemaphoreSlim(4,4),httpSlots=new SemaphoreSlim(4,4),tcpSlots=new SemaphoreSlim(4,4),downloadSlot=new SemaphoreSlim(1,1);
 DateTime proxyChecked=DateTime.MinValue;
 string proxySummary="尚未读取系统代理配置";
 const int MaximumDownloadBytes=10000000, DownloadDeadlineMs=20000;
 const string MeasurementNote="DNS=本机解析（含缓存）；TCP=首个解析 IP 的直连，可能不同于 HTTP 代理路径；HTTP=到响应头的总耗时（含代理/DNS/TCP/TLS）；HTTPS 使用 TLS1.2（当前运行时兼容限定）；HTTP 可达不代表模型推理或服务健康";
 static NetworkCollector(){ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;ServicePointManager.DefaultConnectionLimit=Math.Max(4,ServicePointManager.DefaultConnectionLimit);}
 // Counter deltas always refer to one interface. Never sum VPN and carrier bytes.
 public LocalSample CaptureLocal(string selectedAdapterId){lock(localLock){
  LocalSample sample=new LocalSample();sample.At=DateTime.UtcNow;
  var rateReady=new HashSet<string>();var gatewaysById=new Dictionary<string,string>();var indexes=new Dictionary<string,int>();
  long stamp=Stopwatch.GetTimestamp();NetworkInterface[] interfaces;
  try{interfaces=NetworkInterface.GetAllNetworkInterfaces();}catch{interfaces=new NetworkInterface[0];}
  foreach(NetworkInterface nic in interfaces){try{
   var a=new AdapterInfo{Id=nic.Id,Name=nic.Name,Description=nic.Description,IsVirtual=IsProbablyVirtual(nic),IsUp=nic.OperationalStatus==OperationalStatus.Up,Status=nic.OperationalStatus.ToString()};
   a.Type=nic.NetworkInterfaceType.ToString()+(a.IsVirtual?"（疑似虚拟/隧道）":"");
   a.Mac=FormatMac(nic.GetPhysicalAddress().GetAddressBytes());a.LinkMbps=Math.Max(0,nic.Speed/1000000.0);
   IPInterfaceProperties p=nic.GetIPProperties();var gateways=p.GatewayAddresses.Select(x=>x.Address).Where(IsUsableUnicast).ToList();
   a.Addresses=String.Join(", ",p.UnicastAddresses.Select(x=>x.Address.ToString()).ToArray());
   a.Gateways=String.Join(", ",gateways.Select(x=>x.ToString()).ToArray());
   a.DnsServers=String.Join(", ",p.DnsAddresses.Select(x=>x.ToString()).ToArray());
   IPAddress gateway=gateways.FirstOrDefault(x=>x.AddressFamily==AddressFamily.InterNetwork)??gateways.FirstOrDefault();
   if(gateway!=null)gatewaysById[a.Id]=gateway.ToString();
   try{indexes[a.Id]=p.GetIPv4Properties().Index;}catch{}
   try{
    IPInterfaceStatistics stats=nic.GetIPStatistics();a.ReceivedBytes=stats.BytesReceived;a.SentBytes=stats.BytesSent;
    CounterSnapshot previous;if(counters.TryGetValue(a.Id,out previous)){
     double seconds=(stamp-previous.Stamp)/(double)Stopwatch.Frequency;
     if(seconds>=0.05&&seconds<=10&&a.IsUp&&previous.IsUp){if(a.ReceivedBytes>=previous.Received&&a.SentBytes>=previous.Sent)rateReady.Add(a.Id);a.DownloadBps=a.ReceivedBytes>=previous.Received?(a.ReceivedBytes-previous.Received)/seconds:0;a.UploadBps=a.SentBytes>=previous.Sent?(a.SentBytes-previous.Sent)/seconds:0;}
    }
    counters[a.Id]=new CounterSnapshot{Stamp=stamp,Received=a.ReceivedBytes,Sent=a.SentBytes,IsUp=a.IsUp};
   }catch{counters.Remove(a.Id);}
   sample.Adapters.Add(a);
  }catch{/* Adapter may disappear during enumeration. */}}
  var present=new HashSet<string>(sample.Adapters.Select(x=>x.Id));foreach(string stale in counters.Keys.Where(x=>!present.Contains(x)).ToArray())counters.Remove(stale);
  sample.Adapters=sample.Adapters.OrderByDescending(x=>x.IsUp).ThenBy(x=>x.IsVirtual).ThenBy(x=>x.Name).ToList();
  bool automatic=String.IsNullOrWhiteSpace(selectedAdapterId)||selectedAdapterId=="auto";
  AdapterInfo selected=automatic?null:sample.Adapters.FirstOrDefault(x=>x.Id==selectedAdapterId);bool fallback=!automatic&&selected==null;
  if(automatic||fallback){var metrics=ReadDefaultRouteMetrics();selected=sample.Adapters.Where(x=>x.IsUp&&!x.IsVirtual&&gatewaysById.ContainsKey(x.Id)).OrderBy(x=>GetRouteMetric(x.Id,indexes,metrics)).ThenByDescending(x=>x.LinkMbps).ThenBy(x=>x.Id).FirstOrDefault();}
  if(selected!=null){sample.TrafficAdapterId=selected.Id;sample.TrafficAdapterName=selected.Name+((automatic||fallback)?"（自动选择；仅此接口计数，非逐目标路径证明）":"（手动选择；仅此接口计数）");if(fallback)sample.TrafficAdapterName+="；原接口已不存在";
   sample.DownloadBps=selected.DownloadBps;sample.UploadBps=selected.UploadBps;sample.TrafficRateReady=rateReady.Contains(selected.Id);string gateway;sample.Gateway=gatewaysById.TryGetValue(selected.Id,out gateway)?gateway:null;
  }else sample.TrafficAdapterName="未找到启用且有网关的疑似物理接口；可手动选择";
  if((DateTime.UtcNow-proxyChecked).TotalSeconds>=15){proxySummary=ReadProxySummary();proxyChecked=DateTime.UtcNow;}
  sample.ProxySummary=proxySummary;return sample;
 }}
 public async Task<List<ProbeResult>> ProbeAsync(List<ProbeTarget> targets,int timeoutSeconds){
  if(targets==null)return new List<ProbeResult>();int timeout=Math.Max(1,Math.Min(60,timeoutSeconds))*1000;
  var jobs=new List<Task<ProbeResult>>();foreach(ProbeTarget item in targets.Where(x=>x!=null&&x.Enabled)){ProbeTarget target=item;jobs.Add(ProbeWithLimitAsync(target,timeout));}
  return (await Task.WhenAll(jobs).ConfigureAwait(false)).ToList();
 }
 async Task<ProbeResult> ProbeWithLimitAsync(ProbeTarget target,int timeout){
  await probeSlots.WaitAsync().ConfigureAwait(false);
  try{return await ProbeOneAsync(target,timeout).ConfigureAwait(false);}
  catch(Exception ex){return new ProbeResult{At=DateTime.UtcNow,TargetId=target.Id,Name=target.Name,Group=target.Group,Url=target.Url,Outcome="Skipped",Error="检测器内部异常，本轮不判断目标网络状态："+ex.GetType().Name,Route=MeasurementNote};}
  finally{probeSlots.Release();}
 }
 async Task<ProbeResult> ProbeOneAsync(ProbeTarget target,int timeout){
  var result=new ProbeResult{At=DateTime.UtcNow,TargetId=target.Id,Name=target.Name,Group=target.Group,Url=target.Url,Outcome="Error",Route=MeasurementNote};Uri uri;
  if(!TryGetTargetUri(target.Url,out uri)){result.Outcome="InvalidUrl";result.Error="目标须为有效 http/https 地址且不能嵌入用户名或密码；省略协议按 https 处理";return result;}
  result.Url=uri.AbsoluteUri;
  // HTTP is independent: a proxy can resolve remotely even when local DNS fails.
  Task<DnsObservation> dnsTask=ResolveBoundedAsync(uri.DnsSafeHost,timeout);Task<HttpObservation> httpTask=ProbeHttpBoundedAsync(uri,timeout);
  DnsObservation dns=await dnsTask.ConfigureAwait(false);var errors=new List<string>();result.DnsMs=dns.Milliseconds;
  if(!String.IsNullOrEmpty(dns.Error))errors.Add("本机 DNS："+dns.Error);
  if(dns.Addresses!=null&&dns.Addresses.Length>0){IPAddress address=dns.Addresses[0];result.Address=address.ToString();TcpObservation tcp=await ConnectBoundedAsync(address,uri.Port,timeout).ConfigureAwait(false);result.TcpMs=tcp.Milliseconds;if(!String.IsNullOrEmpty(tcp.Error))errors.Add("首 IP 直连 TCP："+tcp.Error+"（不代表 HTTP 代理路径失败）");}
  else errors.Add("直连 TCP：因无本机解析地址未执行；HTTP 独立执行");
  HttpObservation http=await httpTask.ConfigureAwait(false);result.Reachable=http.Reachable;result.StatusCode=http.StatusCode;result.HttpMs=http.Milliseconds;result.Outcome=http.Outcome;result.Route=http.Route+"；"+MeasurementNote;
  if(!String.IsNullOrEmpty(http.Error))errors.Add("HTTP："+http.Error);result.Error=String.Join("；",errors.ToArray());return result;
 }
 async Task<DnsObservation> ResolveBoundedAsync(string host,int timeout){
  Stopwatch watch=Stopwatch.StartNew();IPAddress literal;if(IPAddress.TryParse(host.Trim('[',']'),out literal))return new DnsObservation{Addresses=new[]{literal},Milliseconds=0};Task<IPAddress[]> operation;
  lock(dnsLock){if(!dnsInFlight.TryGetValue(host,out operation)){
   if(dnsInFlight.Count>=4)return new DnsObservation{Error="系统解析仍在处理中，达到 4 个未完成解析上限"};
   operation=StartWorker(()=>Dns.GetHostAddresses(host));dnsInFlight[host]=operation;Task<IPAddress[]> tracked=operation;
   operation.ContinueWith(t=>{if(t.IsFaulted){AggregateException ignored=t.Exception;}lock(dnsLock){Task<IPAddress[]> current;if(dnsInFlight.TryGetValue(host,out current)&&Object.ReferenceEquals(current,tracked))dnsInFlight.Remove(host);}},TaskScheduler.Default);
  }}
  if(!await CompletesWithinAsync(operation,timeout).ConfigureAwait(false))return new DnsObservation{Error="解析超时；系统后台解析受并发上限约束"};
  try{IPAddress[] addresses=(await operation.ConfigureAwait(false)).Where(x=>x.AddressFamily==AddressFamily.InterNetwork||x.AddressFamily==AddressFamily.InterNetworkV6).ToArray();return addresses.Length==0?new DnsObservation{Error="未返回 IPv4/IPv6 地址"}:new DnsObservation{Addresses=addresses,Milliseconds=watch.Elapsed.TotalMilliseconds};}
  catch(SocketException ex){return new DnsObservation{Error=ex.SocketErrorCode.ToString()};}catch(Exception ex){return new DnsObservation{Error=ex.GetType().Name};}
 }
 async Task<TcpObservation> ConnectBoundedAsync(IPAddress address,int port,int timeout){
  if(!tcpSlots.Wait(0))return new TcpObservation{Error="先前连接尚未结束，已达到并发上限"};Socket socket;
  try{socket=new Socket(address.AddressFamily,SocketType.Stream,ProtocolType.Tcp);}catch(Exception ex){tcpSlots.Release();return new TcpObservation{Error=ex.GetType().Name};}
  Task<double> operation=StartWorker(()=>{Stopwatch watch=Stopwatch.StartNew();socket.Connect(new IPEndPoint(address,port));return watch.Elapsed.TotalMilliseconds;});
  operation.ContinueWith(t=>{if(t.IsFaulted){AggregateException ignored=t.Exception;}try{socket.Close();}catch{}tcpSlots.Release();},TaskScheduler.Default);
  if(!await CompletesWithinAsync(operation,timeout).ConfigureAwait(false)){try{socket.Close();}catch{}return new TcpObservation{Error="连接超时"};}
  try{return new TcpObservation{Milliseconds=await operation.ConfigureAwait(false)};}catch(SocketException ex){return new TcpObservation{Error=ex.SocketErrorCode.ToString()};}catch(Exception ex){return new TcpObservation{Error=ex.GetType().Name};}
 }
 // Slots stay held until underlying work actually ends, including after Abort.
 async Task<HttpObservation> ProbeHttpBoundedAsync(Uri uri,int timeout){
  if(!await httpSlots.WaitAsync(timeout).ConfigureAwait(false))return new HttpObservation{Outcome="Skipped",Error="等待检测器 HTTP 槽位超时，本轮未发送 HTTP 请求；不能作为目标网络失败证据",Route="系统代理：本轮未解析"};HttpWebRequest request;
  try{request=CreateRequest(uri,"HEAD",timeout);}catch(Exception ex){httpSlots.Release();return new HttpObservation{Outcome="Skipped",Error="本机请求配置异常："+ex.GetType().Name,Route="系统代理：配置读取失败"};}
  HttpProgress progress=new HttpProgress();Task<HttpObservation> operation=StartWorker(()=>ExecuteHttp(request,uri,progress));operation.ContinueWith(t=>{if(t.IsFaulted){AggregateException ignored=t.Exception;}httpSlots.Release();},TaskScheduler.Default);
  if(!await CompletesWithinAsync(operation,timeout).ConfigureAwait(false)){try{request.Abort();}catch{}return new HttpObservation{Outcome=progress.RequestStarted?"Timeout":"Skipped",Error=progress.RequestStarted?"HTTP 路径在设定时限内未取得响应头":"系统代理解析未及时完成，本轮未发送 HTTP；不判断目标网络失败",Route=progress.Route};}
  try{return await operation.ConfigureAwait(false);}catch(Exception ex){return new HttpObservation{Outcome="Skipped",Error="检测器执行异常："+ex.GetType().Name,Route="系统代理：路径未确定"};}
 }
 static HttpObservation ExecuteHttp(HttpWebRequest request,Uri uri,HttpProgress progress){
  Stopwatch watch=Stopwatch.StartNew();string route=DescribeProxyRoute(request.Proxy,uri);progress.Route=route;progress.RequestStarted=true;
  try{using(HttpWebResponse response=(HttpWebResponse)request.GetResponse())return FromResponse(response,watch.Elapsed.TotalMilliseconds,route);}
  catch(WebException ex){using(HttpWebResponse response=ex.Response as HttpWebResponse){if(response!=null)return FromResponse(response,watch.Elapsed.TotalMilliseconds,route);}return new HttpObservation{Outcome=IsLocalConfigurationError(ex)?"Skipped":WebOutcome(ex.Status),Error=IsLocalConfigurationError(ex)?"本机请求或安全协议配置异常；未形成有效 HTTP 探测，不能判断网络失败":WebError(ex.Status),Route=route};}
  catch(Exception ex){return new HttpObservation{Outcome="Skipped",Error="本机检测器执行异常："+ex.GetType().Name+"；不能判断目标网络失败",Route=route};}
 }
 static HttpObservation FromResponse(HttpWebResponse response,double elapsed,string route){
  int status=(int)response.StatusCode;string outcome,note=null;
  if(status==407){outcome="ProxyAuthRequired";note="407 代理要求认证，尚未验证目标服务；仅确认收到 HTTP 层响应";}
  else if(status==401){outcome="AuthRequired";note="401 需要身份验证；已经收到 HTTP 响应";}
  else if(status==403){outcome="Forbidden";note="403 请求被拒绝；可能涉及权限、地区或策略，不能仅据此确定";}
  else if(status==404){outcome="NotFound";note="404 路径不存在；已经收到 HTTP 响应";}
  else if(status==405){outcome="MethodNotAllowed";note="405 不接受 HEAD；未补发 GET，已经收到 HTTP 响应";}
  else if(status==429){outcome="RateLimited";note="429 请求受限；不证明账号额度或模型推理状态";}
  else if(status>=500){outcome="ServerError";note=status+" 服务端/中间代理错误；已经收到 HTTP 响应";}
  else if(status>=400){outcome="HttpError";note=status+" HTTP 错误响应";}
  else if(status>=300){outcome="Redirect";note=status+" 重定向；未自动跟随，未验证新目标";}
  else if(status>=200)outcome="OK";else outcome="HttpResponse";
  return new HttpObservation{Reachable=true,StatusCode=status,Milliseconds=elapsed,Outcome=outcome,Error=note,Route=route};
 }
 public async Task<double?> PingGatewayAsync(string gateway){
  IPAddress address;if(String.IsNullOrWhiteSpace(gateway)||!IPAddress.TryParse(gateway,out address))return null;Ping ping=new Ping();Task<PingReply> operation;
  try{operation=ping.SendPingAsync(address,1500);}catch{ping.Dispose();return null;}
  if(!await CompletesWithinAsync(operation,1700).ConfigureAwait(false)){try{ping.SendAsyncCancel();}catch{}operation.ContinueWith(t=>{if(t.IsFaulted){AggregateException ignored=t.Exception;}ping.Dispose();},TaskScheduler.Default);return null;}
  try{PingReply reply=await operation.ConfigureAwait(false);return reply.Status==IPStatus.Success?(double?)reply.RoundtripTime:null;}catch{return null;}finally{ping.Dispose();}
 }
 public Task<List<DeviceInfo>> GetNeighborsAsync(){return Task.Run(()=>{var devices=ReadNeighborCache();AppendLocalInterfaces(devices);return devices;});}
 // Only reads OS caches: no subnet scan, reverse DNS, broadcast or vendor lookup.
 static void AppendLocalInterfaces(List<DeviceInfo> devices){
  try{foreach(NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces()){
   try{if(nic.OperationalStatus!=OperationalStatus.Up||nic.NetworkInterfaceType==NetworkInterfaceType.Loopback)continue;
    foreach(UnicastIPAddressInformation entry in nic.GetIPProperties().UnicastAddresses){IPAddress ip=entry.Address;if(!IsUsableUnicast(ip))continue;
     devices.Add(new DeviceInfo{Ip=ip.ToString(),Mac=FormatMac(nic.GetPhysicalAddress().GetAddressBytes()),Name=Environment.MachineName,Hint="本机 Windows 自报；接口 "+nic.Name+"；不是通过反向 DNS 查询获得",State="本机接口已启用",Source="本机接口 / Windows 自报",ObservedAt=DateTime.UtcNow});
    }
   }catch{}
  }}catch{}
 }
 static List<DeviceInfo> ReadNeighborCache(){
  var devices=new List<DeviceInfo>();IntPtr table=IntPtr.Zero;
  try{
   if(GetIpNetTable2(0,out table)!=0||table==IntPtr.Zero)return ReadLegacyArpCache();
   int count=Math.Min(16384,Math.Max(0,Marshal.ReadInt32(table)));DateTime collected=DateTime.UtcNow;
   // ULONG count + alignment padding; MIB_IPNET_ROW2 is 88 bytes on Windows.
   for(int index=0;index<count;index++){
    byte[] row=new byte[88];Marshal.Copy(IntPtr.Add(table,8+index*88),row,0,row.Length);ushort family=BitConverter.ToUInt16(row,0);IPAddress ip;
    if(family==2)ip=new IPAddress(Slice(row,4,4));else if(family==23)ip=new IPAddress(Slice(row,8,16),BitConverter.ToUInt32(row,24));else continue;if(!IsUsableUnicast(ip))continue;
    int macLength=(int)Math.Min(32u,BitConverter.ToUInt32(row,72));uint state=BitConverter.ToUInt32(row,76);
    devices.Add(new DeviceInfo{Ip=ip.ToString(),Mac=FormatMac(Slice(row,40,macLength)),Name="未知",Hint="设备类型未知；仅缓存记录，不保证当前在线；未发送反向名称查询",State=NeighborState(state),Source="Windows 邻居缓存；接口 "+BitConverter.ToUInt32(row,28),DownloadBps=null,UploadBps=null,ObservedAt=collected});
   }
  }catch(EntryPointNotFoundException){return ReadLegacyArpCache();}catch(DllNotFoundException){return devices;}catch{}
  finally{if(table!=IntPtr.Zero)FreeMibTable(table);}return devices.OrderBy(x=>x.Ip).ThenBy(x=>x.Source).ToList();
 }
 static List<DeviceInfo> ReadLegacyArpCache(){
  var devices=new List<DeviceInfo>();int length=0;IntPtr table=IntPtr.Zero;
  try{
   if(GetIpNetTable(IntPtr.Zero,ref length,false)!=122||length<4||length>4*1024*1024)return devices;table=Marshal.AllocHGlobal(length);if(GetIpNetTable(table,ref length,false)!=0)return devices;
   int count=Math.Min(Math.Max(0,Marshal.ReadInt32(table)),(length-4)/24);
   for(int index=0;index<count;index++){
    byte[] row=new byte[24];Marshal.Copy(IntPtr.Add(table,4+index*24),row,0,24);IPAddress ip=new IPAddress(Slice(row,16,4));if(!IsUsableUnicast(ip))continue;int macLength=(int)Math.Min(8u,BitConverter.ToUInt32(row,4));uint type=BitConverter.ToUInt32(row,20);
    devices.Add(new DeviceInfo{Ip=ip.ToString(),Mac=FormatMac(Slice(row,8,macLength)),Name="未知",Hint="设备类型未知；ARP 缓存不保证当前在线",State=type==4?"静态缓存":type==3?"动态缓存":"无效/其他缓存",Source="Windows IPv4 ARP 缓存；接口 "+BitConverter.ToUInt32(row,0),ObservedAt=DateTime.UtcNow});
   }
  }catch{}finally{if(table!=IntPtr.Zero)Marshal.FreeHGlobal(table);}return devices;
 }
 public List<ConnectionInfo> GetConnections(){var connections=new List<ConnectionInfo>();var names=new Dictionary<int,string>();ReadTcpConnections(2,connections,names);ReadTcpConnections(23,connections,names);return connections.OrderBy(x=>x.ProcessName).ThenBy(x=>x.Pid).ThenBy(x=>x.RemoteEndpoint).ToList();}
 static void ReadTcpConnections(int family,List<ConnectionInfo> result,Dictionary<int,string> names){
  int length=0;IntPtr table=IntPtr.Zero;
  try{
   if(GetExtendedTcpTable(IntPtr.Zero,ref length,false,family,5,0)!=122||length<4||length>16*1024*1024)return;table=Marshal.AllocHGlobal(length);if(GetExtendedTcpTable(table,ref length,false,family,5,0)!=0)return;
   int rowSize=family==2?24:56,count=Math.Min(Math.Max(0,Marshal.ReadInt32(table)),(length-4)/rowSize);count=Math.Min(count,20000);
   for(int index=0;index<count;index++){
    byte[] row=new byte[rowSize];Marshal.Copy(IntPtr.Add(table,4+index*rowSize),row,0,row.Length);IPAddress local,remote;int localPort,remotePort,pid,state;
    if(family==2){state=BitConverter.ToInt32(row,0);local=new IPAddress(Slice(row,4,4));localPort=ReadPort(row,8);remote=new IPAddress(Slice(row,12,4));remotePort=ReadPort(row,16);pid=BitConverter.ToInt32(row,20);}
    else{local=new IPAddress(Slice(row,0,16),BitConverter.ToUInt32(row,16));localPort=ReadPort(row,20);remote=new IPAddress(Slice(row,24,16),BitConverter.ToUInt32(row,40));remotePort=ReadPort(row,44);state=BitConverter.ToInt32(row,48);pid=BitConverter.ToInt32(row,52);}
    string name;if(!names.TryGetValue(pid,out name)){try{using(Process process=Process.GetProcessById(pid))name=process.ProcessName;}catch{name=pid==0?"系统/无所属进程":"名称不可读或进程已退出";}names[pid]=name;}
    result.Add(new ConnectionInfo{Pid=pid,ProcessName=name,LocalEndpoint=FormatEndpoint(local,localPort),RemoteEndpoint=FormatEndpoint(remote,remotePort),State=((TcpState)state).ToString()});
   }
  }catch{}finally{if(table!=IntPtr.Zero)Marshal.FreeHGlobal(table);}
 }
 public async Task<SpeedTestResult> MeasureDownloadAsync(){
  if(!downloadSlot.Wait(0))return new SpeedTestResult{At=DateTime.UtcNow,Error="已有手动测速或其终止操作尚未结束",Route="单目标当前路径估计"};
  Uri uri=new Uri("https://speed.cloudflare.com/__down?bytes=10000000");HttpWebRequest request;
  try{request=CreateRequest(uri,"GET",DownloadDeadlineMs);request.ReadWriteTimeout=3000;}catch(Exception ex){downloadSlot.Release();return new SpeedTestResult{At=DateTime.UtcNow,Error=ex.GetType().Name};}
  var progress=new DownloadProgress();Stopwatch wall=Stopwatch.StartNew();Task<SpeedTestResult> operation=StartWorker(()=>Download(request,uri,progress,wall));
  operation.ContinueWith(t=>{if(t.IsFaulted){AggregateException ignored=t.Exception;}downloadSlot.Release();},TaskScheduler.Default);
  if(!await CompletesWithinAsync(operation,DownloadDeadlineMs).ConfigureAwait(false)){
   try{request.Abort();}catch{}long received=Interlocked.Read(ref progress.Bytes);double seconds=wall.Elapsed.TotalSeconds;
   return new SpeedTestResult{At=DateTime.UtcNow,Bytes=received,Seconds=seconds,Mbps=seconds>0?received*8.0/seconds/1000000.0:0,Error="达到 20 秒总时限，下载已中止；仅统计已收到的数据",Route=progress.Route+"；单目标当前路径估计，包含建连开销；不是套餐带宽"};
  }
  try{return await operation.ConfigureAwait(false);}catch(Exception ex){return new SpeedTestResult{At=DateTime.UtcNow,Error=ex.GetType().Name,Route="单目标当前路径估计"};}
 }
 static SpeedTestResult Download(HttpWebRequest request,Uri uri,DownloadProgress progress,Stopwatch wall){
  string error=null;progress.Route=DescribeProxyRoute(request.Proxy,uri);
  try{using(HttpWebResponse response=(HttpWebResponse)request.GetResponse()){
   int status=(int)response.StatusCode;if(status<200||status>=300)error="测速目标返回 HTTP "+status+"；未跟随重定向";
   else using(System.IO.Stream stream=response.GetResponseStream()){
    byte[] buffer=new byte[32768];while(Interlocked.Read(ref progress.Bytes)<MaximumDownloadBytes&&wall.ElapsedMilliseconds<DownloadDeadlineMs){int remaining=(int)(MaximumDownloadBytes-Interlocked.Read(ref progress.Bytes));int read=stream.Read(buffer,0,Math.Min(buffer.Length,remaining));if(read<=0)break;Interlocked.Add(ref progress.Bytes,read);}
    if(wall.ElapsedMilliseconds>=DownloadDeadlineMs)error="达到 20 秒总时限；仅统计已收到的数据";
   }
  }}catch(WebException ex){HttpWebResponse response=ex.Response as HttpWebResponse;if(response!=null){error="测速目标返回 HTTP "+(int)response.StatusCode;response.Close();}else error=WebError(ex.Status);}catch(Exception ex){error=ex.GetType().Name;}
  double seconds=wall.Elapsed.TotalSeconds;long bytes=Interlocked.Read(ref progress.Bytes);if(bytes==0&&String.IsNullOrEmpty(error))error="目标未返回可计量的下载内容";
  return new SpeedTestResult{At=DateTime.UtcNow,Bytes=bytes,Seconds=seconds,Mbps=seconds>0?bytes*8.0/seconds/1000000.0:0,Error=error,Route=progress.Route+"；Cloudflare 单目标当前路径估计，最多 10,000,000 字节/20 秒，包含建连开销；不是套餐带宽"};
 }
 static HttpWebRequest CreateRequest(Uri uri,string method,int timeout){
  HttpWebRequest request=(HttpWebRequest)WebRequest.Create(uri);request.Method=method;request.AllowAutoRedirect=false;request.Proxy=WebRequest.DefaultWebProxy;request.Timeout=timeout;request.ReadWriteTimeout=timeout;request.KeepAlive=true;request.UserAgent="NetScope/1.0 (Windows network diagnostics)";request.Accept="*/*";request.AutomaticDecompression=DecompressionMethods.None;request.UseDefaultCredentials=false;request.PreAuthenticate=false;return request;
 }
 static string DescribeProxyRoute(IWebProxy proxy,Uri uri){
  if(proxy==null)return "该 URL 的系统代理解析：直连（仍可能经过 VPN/TUN）";
  try{Uri destination=proxy.GetProxy(uri);if(destination==null||destination.Equals(uri))return "该 URL 的系统代理解析：直连（仍可能经过 VPN/TUN）";return "该 URL 的系统代理解析："+destination.Scheme+"://"+destination.Host+":"+destination.Port+"（不推断隧道出口）";}
  catch(Exception ex){return "该 URL 的系统代理解析未确定："+ex.GetType().Name;}
 }
 static Task<T> StartWorker<T>(Func<T> action){return Task.Factory.StartNew(action,CancellationToken.None,TaskCreationOptions.LongRunning,TaskScheduler.Default);}
 static async Task<bool> CompletesWithinAsync(Task operation,int timeout){using(var timer=new CancellationTokenSource()){Task deadline=Task.Delay(timeout,timer.Token),finished=await Task.WhenAny(operation,deadline).ConfigureAwait(false);if(Object.ReferenceEquals(finished,operation)){timer.Cancel();return true;}return operation.IsCompleted;}}
 static bool TryGetTargetUri(string text,out Uri uri){uri=null;if(String.IsNullOrWhiteSpace(text))return false;text=text.Trim();if(text.IndexOf("://",StringComparison.Ordinal)<0)text="https://"+text;return Uri.TryCreate(text,UriKind.Absolute,out uri)&&(uri.Scheme==Uri.UriSchemeHttp||uri.Scheme==Uri.UriSchemeHttps)&&!String.IsNullOrWhiteSpace(uri.Host)&&String.IsNullOrEmpty(uri.UserInfo);}
 static string ReadProxySummary(){
  var parts=new List<string>();
  try{using(RegistryKey key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Internet Settings",false)){
   if(key==null)parts.Add("当前用户系统代理配置不可读");
   else{int enabled=Convert.ToInt32(key.GetValue("ProxyEnable",0));string server=Convert.ToString(key.GetValue("ProxyServer","")),pac=Convert.ToString(key.GetValue("AutoConfigURL",""));parts.Add(enabled!=0?"手动系统代理："+SanitizeProxyServers(server):"手动系统代理：未启用");
    if(!String.IsNullOrWhiteSpace(pac)){Uri pacUri;parts.Add(Uri.TryCreate(pac,UriKind.Absolute,out pacUri)?"PAC 配置："+pacUri.Scheme+"://"+pacUri.Host+":"+pacUri.Port+"/…（路径省略）":"存在 PAC 配置（地址格式未识别）");}
    using(RegistryKey connections=key.OpenSubKey("Connections",false)){byte[] settings=connections==null?null:connections.GetValue("DefaultConnectionSettings") as byte[];if(settings!=null&&settings.Length>8)parts.Add((settings[8]&8)!=0?"自动检测代理：配置为启用":"自动检测代理：配置为关闭");}
   }
  }}catch{parts.Add("系统代理注册表摘要读取失败");}
  string processes=FindTunnelProcessNames();if(!String.IsNullOrEmpty(processes))parts.Add("观测到相关进程："+processes+"（不证明隧道生效）");parts.Add("配置摘要不证明实际路径；以每个 URL 的代理解析为准；未读取账号或命令行");return String.Join("；",parts.ToArray());
 }
 static string SanitizeProxyServers(string value){
  if(String.IsNullOrWhiteSpace(value))return "已启用但未发现服务器地址";var endpoints=new List<string>();
  foreach(string part in value.Split(';')){string endpoint=part.Trim(),prefix="";int equals=endpoint.IndexOf('=');if(equals>0){string protocol=endpoint.Substring(0,equals).ToLowerInvariant();if(protocol=="http"||protocol=="https"||protocol=="ftp"||protocol=="socks")prefix=protocol+"=";endpoint=endpoint.Substring(equals+1);}Uri uri;if(Uri.TryCreate(endpoint.IndexOf("://",StringComparison.Ordinal)>=0?endpoint:"http://"+endpoint,UriKind.Absolute,out uri)&&!String.IsNullOrEmpty(uri.Host))endpoints.Add(prefix+uri.Host+":"+uri.Port);}
  return endpoints.Count==0?"已配置（地址格式未识别）":String.Join(", ",endpoints.ToArray());
 }
 static string FindTunnelProcessNames(){
  string[] terms={"clash","mihomo","wireguard","openvpn","tailscale","zerotier","v2ray","xray","sing-box","shadowsocks","hiddify","nekoray","warp-svc","protonvpn","nordvpn","forticlient"};var found=new List<string>();
  try{foreach(Process process in Process.GetProcesses()){using(process){try{string name=process.ProcessName,lower=name.ToLowerInvariant();if(terms.Any(x=>lower.Contains(x))&&!found.Contains(name))found.Add(name);}catch{}}}}catch{}return String.Join(", ",found.OrderBy(x=>x).Take(8).ToArray());
 }
 static bool IsProbablyVirtual(NetworkInterface nic){
  if(nic.NetworkInterfaceType==NetworkInterfaceType.Loopback||nic.NetworkInterfaceType==NetworkInterfaceType.Tunnel||nic.NetworkInterfaceType==NetworkInterfaceType.Ppp)return true;
  string text=(nic.Name+" "+nic.Description).ToLowerInvariant();string[] terms={"virtual","hyper-v","vethernet","vmware","virtualbox","wintun","wireguard","vpn","clash","mihomo","tailscale","zerotier","hamachi","radmin","nordlynx","anyconnect","fortinet","forticlient","mullvad","proton","tap","tun"};return terms.Any(x=>text.Contains(x));
 }
 static Dictionary<int,long> ReadDefaultRouteMetrics(){
  var metrics=new Dictionary<int,long>();int length=0;IntPtr table=IntPtr.Zero;
  try{
   if(GetIpForwardTable(IntPtr.Zero,ref length,false)!=122||length<4||length>4*1024*1024)return metrics;table=Marshal.AllocHGlobal(length);if(GetIpForwardTable(table,ref length,false)!=0)return metrics;int count=Math.Min(Math.Max(0,Marshal.ReadInt32(table)),(length-4)/56);
   for(int i=0;i<count;i++){IntPtr row=IntPtr.Add(table,4+i*56);if(Marshal.ReadInt32(row,0)!=0||Marshal.ReadInt32(row,4)!=0)continue;int index=Marshal.ReadInt32(row,16),type=Marshal.ReadInt32(row,20);if(type!=3&&type!=4)continue;long metric=unchecked((uint)Marshal.ReadInt32(row,36)),existing;if(!metrics.TryGetValue(index,out existing)||metric<existing)metrics[index]=metric;}
  }catch{}finally{if(table!=IntPtr.Zero)Marshal.FreeHGlobal(table);}return metrics;
 }
 static long GetRouteMetric(string id,Dictionary<string,int> indexes,Dictionary<int,long> metrics){int index;long metric;return indexes.TryGetValue(id,out index)&&metrics.TryGetValue(index,out metric)?metric:Int64.MaxValue;}
 static bool IsUsableUnicast(IPAddress address){if(address==null||IPAddress.IsLoopback(address)||address.Equals(IPAddress.Any)||address.Equals(IPAddress.IPv6Any)||address.IsIPv6Multicast)return false;byte[] bytes=address.GetAddressBytes();return address.AddressFamily!=AddressFamily.InterNetwork||(bytes[0]>0&&bytes[0]<224);}
 static string NeighborState(uint state){switch(state){case 0:return "不可达（缓存状态）";case 1:return "不完整缓存";case 2:return "探测中（系统状态）";case 3:return "延迟确认";case 4:return "陈旧缓存";case 5:return "可达（缓存状态）";case 6:return "静态缓存";default:return "未知缓存状态";}}
 static bool IsLocalConfigurationError(Exception error){for(int i=0;error!=null&&i<8;i++,error=error.InnerException){if(error is ArgumentException||error is InvalidOperationException||error is NotSupportedException||error is System.Security.SecurityException)return true;}return false;}
 static string WebOutcome(WebExceptionStatus status){switch(status){case WebExceptionStatus.Timeout:case WebExceptionStatus.RequestCanceled:return "Timeout";case WebExceptionStatus.NameResolutionFailure:return "DnsError";case WebExceptionStatus.ProxyNameResolutionFailure:return "ProxyError";case WebExceptionStatus.TrustFailure:case WebExceptionStatus.SecureChannelFailure:return "TlsError";case WebExceptionStatus.ConnectFailure:case WebExceptionStatus.ConnectionClosed:case WebExceptionStatus.ReceiveFailure:case WebExceptionStatus.SendFailure:return "ConnectError";default:return "Error";}}
 static string WebError(WebExceptionStatus status){switch(status){case WebExceptionStatus.Timeout:return "请求超时，未取得 HTTP 响应";case WebExceptionStatus.RequestCanceled:return "请求已因时限或终止操作取消";case WebExceptionStatus.NameResolutionFailure:return "HTTP 路径名称解析失败";case WebExceptionStatus.ProxyNameResolutionFailure:return "HTTP 系统代理名称解析失败";case WebExceptionStatus.TrustFailure:return "证书验证失败；未绕过证书校验";case WebExceptionStatus.SecureChannelFailure:return "TLS 安全通道建立失败";case WebExceptionStatus.ConnectFailure:return "HTTP 路径连接失败（可能是目标或代理）";default:return status.ToString()+"；未取得 HTTP 响应";}}
 static byte[] Slice(byte[] bytes,int offset,int count){byte[] result=new byte[count];Buffer.BlockCopy(bytes,offset,result,0,count);return result;}
 static string FormatMac(byte[] bytes){return bytes==null||bytes.Length==0?"未知":BitConverter.ToString(bytes);}
 static int ReadPort(byte[] bytes,int offset){return (bytes[offset]<<8)|bytes[offset+1];}
 static string FormatEndpoint(IPAddress address,int port){return address.AddressFamily==AddressFamily.InterNetworkV6?"["+address+"]:"+port:address+":"+port;}
 class CounterSnapshot{public long Stamp;public long Received;public long Sent;public bool IsUp;}
 class DnsObservation{public IPAddress[] Addresses;public double? Milliseconds;public string Error;}
 class TcpObservation{public double? Milliseconds;public string Error;}
 class HttpProgress{public volatile bool RequestStarted;public volatile string Route="该 URL 的系统代理尚未完成解析";}
 class HttpObservation{public bool Reachable;public int? StatusCode;public double? Milliseconds;public string Outcome;public string Error;public string Route;}
 class DownloadProgress{public long Bytes;public volatile string Route="系统代理路径尚未确定";}
 [DllImport("iphlpapi.dll")]static extern uint GetIpNetTable2(ushort family,out IntPtr table);
 [DllImport("iphlpapi.dll")]static extern void FreeMibTable(IntPtr memory);
 [DllImport("iphlpapi.dll")]static extern uint GetIpNetTable(IntPtr table,ref int size,[MarshalAs(UnmanagedType.Bool)]bool order);
 [DllImport("iphlpapi.dll")]static extern uint GetExtendedTcpTable(IntPtr table,ref int size,[MarshalAs(UnmanagedType.Bool)]bool order,int family,int tableClass,uint reserved);
 [DllImport("iphlpapi.dll")]static extern uint GetIpForwardTable(IntPtr table,ref int size,[MarshalAs(UnmanagedType.Bool)]bool order);
}}




