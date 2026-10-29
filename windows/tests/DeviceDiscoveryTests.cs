using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Threading;
using System.Threading.Tasks;
using NetScope;
class DeviceDiscoveryTests {
 static int checks;
 static void Check(bool ok,string name){if(!ok)throw new Exception(name);checks++;Console.WriteLine("PASS "+name);}
 static IPAddress IP(string value){return IPAddress.Parse(value);}
 static DiscoveryPlan Plan(){return new DiscoveryPlan{AdapterId="synthetic",AdapterName="fake",InterfaceIndex=7,LocalAddress=IP("10.0.0.1"),
  Scope="synthetic 10.0.0.0/24",Targets=Enumerable.Range(2,20).Select(x=>IP("10.0.0."+x)).ToList()};}
 static DeviceInfo Row(string ip,string mac,string source){return new DeviceInfo{Ip=ip,Mac=mac,Source=source,Name="未知",State="缓存"};}
 static void Main(){Run().GetAwaiter().GetResult();Console.WriteLine("RESULT "+checks+" discovery checks passed; fake routes/transports/cache only; NO LAN probes.");}
 static async Task Run(){
  foreach(var value in new[]{"10.0.0.1","172.16.0.1","172.31.255.254","192.168.1.1"})Check(DiscoveryPlanning.IsPrivateIPv4(IP(value)),"RFC1918 accepts "+value);
  foreach(var value in new[]{"8.8.8.8","127.0.0.1","169.254.1.1","172.15.0.1","172.32.0.1","192.169.1.1","::1"})Check(!DiscoveryPlanning.IsPrivateIPv4(IP(value)),"outside scope rejected "+value);
  var subnet=DiscoveryPlanning.Targets(IP("10.12.34.56"),IP("255.0.0.0"));
  Check(subnet.Count==253&&subnet.All(x=>x.ToString().StartsWith("10.12.34.")),"large real subnet capped to selected /24 intersection");
  Check(!subnet.Contains(IP("10.12.34.0"))&&!subnet.Contains(IP("10.12.34.255"))&&!subnet.Contains(IP("10.12.34.56")),"network broadcast and own address excluded");
  Check(DiscoveryPlanning.Scope(IP("10.12.34.56"),IP("255.0.0.0"))=="10.12.34.0/24","reported scope is exact bounded network");
  var small=DiscoveryPlanning.Targets(IP("192.168.8.130"),IP("255.255.255.128"));
  Check(small.Count==125&&small.All(x=>x.GetAddressBytes()[3]>128&&x.GetAddressBytes()[3]<255),"real /25 does not expand to full /24");
  Check(DiscoveryPlanning.Targets(IP("10.0.0.1"),IP("255.255.255.252")).Count==1,"small point subnet remains bounded");
  Check(DiscoveryPlanning.Targets(IP("10.0.0.1"),IP("255.255.255.255")).Count==0,"host route yields no other candidates");
  bool rejected=false;try{DiscoveryPlanning.Targets(IP("10.0.0.1"),IP("255.0.255.0"));}catch(ArgumentException){rejected=true;}
  Check(rejected,"noncontiguous mask rejected");
  rejected=false;try{DiscoveryPlanning.Targets(IP("8.8.8.8"),IP("255.255.255.0"));}catch(ArgumentException){rejected=true;}
  Check(rejected,"public subnet never planned");
  Check(DiscoveryPlanning.IsPhysicalType(NetworkInterfaceType.Wireless80211)&&DiscoveryPlanning.IsPhysicalType(NetworkInterfaceType.Ethernet)&&!DiscoveryPlanning.IsPhysicalType(NetworkInterfaceType.Tunnel),"only wired and Wi-Fi link types permitted");
  foreach(var mac in new[]{"00:11:22:33:44:55","02-AA-BB-CC-DD-EE"})Check(DiscoveryPlanning.ValidUnicastMac(mac),"valid unicast MAC "+mac);
  foreach(var mac in new[]{"00:00:00:00:00:00","FF:FF:FF:FF:FF:FF","01:00:5e:00:00:01","未知","bad"})Check(!DiscoveryPlanning.ValidUnicastMac(mac),"unconfirmed MAC rejected "+mac);
  var rejectedSelection=await DeviceDiscovery.DiscoverAsync("auto",CancellationToken.None);
  Check(rejectedSelection.Attempted==0&&!String.IsNullOrEmpty(rejectedSelection.Error),"public API rejects unspecified auto interface before any network enumeration or probe");
  using(var cancelled=new CancellationTokenSource()){
   cancelled.Cancel();var stopped=await DeviceDiscovery.DiscoverAsync("anything",cancelled.Token);
   Check(stopped.Cancelled&&stopped.Attempted==0,"public pre-cancel exits before interface resolution or probe");
  }
  var plan=Plan();int active=0,maximum=0,calls=0;object sync=new object();
  Func<IPAddress,int,CancellationToken,Action,Task<DiscoveryProbeOutcome>> fake=async(address,timeout,token,sent)=>{
   sent();lock(sync){active++;maximum=Math.Max(maximum,active);calls++;}
   try{await Task.Delay(20,token);return address.GetAddressBytes()[3]%4==0?DiscoveryProbeOutcome.Replied:DiscoveryProbeOutcome.NoReply;}
   finally{lock(sync)active--;}
  };
  var runner=new DiscoveryRunner(address=>address.GetAddressBytes()[3]%2==0,fake,token=>Task.FromResult(new List<DeviceInfo>()),2000);
  var result=await runner.RunAsync(plan,new List<DeviceInfo>(),Stopwatch.StartNew(),CancellationToken.None);
  Check(result.Attempted==10&&result.Replied==5&&result.Skipped==10,"attempt/reply/skipped counts preserve route refusals and no-replies");
  Check(maximum<=8&&maximum>1&&active==0,"bounded parallel work drains before completion");
  Check(result.RepliedAddresses.Count==5&&result.RepliedAddresses.All(x=>IP(x).GetAddressBytes()[3]%4==0),"only actual fake replies reported");
  Check(result.Devices.Count==5&&result.Devices.All(x=>x.State.Contains("本次ICMP回应")&&x.Source.Contains("接口 7")&&x.Mac=="未知"),"reply without MAC kept with precise evidence and interface index");
  Check(result.Note.Contains("不是完整")&&result.Note.Contains("不回应仍未知"),"result does not claim full network coverage or absence");
  int deniedCalls=0;
  runner=new DiscoveryRunner(address=>false,(address,timeout,token,sent)=>{deniedCalls++;return Task.FromResult(DiscoveryProbeOutcome.Replied);},token=>Task.FromResult(new List<DeviceInfo>()),2000);
  result=await runner.RunAsync(plan,new List<DeviceInfo>(),Stopwatch.StartNew(),CancellationToken.None);
  Check(deniedCalls==0&&result.Attempted==0&&result.Replied==0&&result.Skipped==20,"VPN/other route skips all sends");
  var old=Row("10.0.0.99","未知","Windows 邻居缓存；接口 7");
  var imported=Row("192.168.99.2","00:11:22:33:44:22","网关导入快照");
  var named=Row("10.0.0.4","00:11:22:33:44:04","Windows 邻居缓存；接口 7");named.Name="人工名称";named.NameSource="人工确认 / 本地标签";named.ReportedName="network-name";named.ReportedNameSource=DeviceIdentity.NetworkNameSource;
  var after=new[]{Row("10.0.0.2","00:11:22:33:44:02","Windows 邻居缓存；接口 7"),
   Row("10.0.0.3","00:00:00:00:00:00","Windows 邻居缓存；接口 7"),
   Row("10.0.0.4","00:11:22:33:44:04","Windows 邻居缓存；接口 7"),
   Row("10.0.0.6","00:11:22:33:44:06","Windows 邻居缓存；接口 8"),
   Row("10.0.1.2","00:11:22:33:44:08","Windows 邻居缓存；接口 7")};
  var merged=DiscoveryRunner.MergeDevices(plan,new[]{old,imported,named},after,new[]{"10.0.0.4","10.0.0.8"},DateTime.UtcNow);
  Check(merged.Any(x=>x.Ip==old.Ip)&&merged.Any(x=>x.Source=="网关导入快照"),"prior records retained without expanding discovery scope");
  Check(merged.Any(x=>x.Ip=="10.0.0.2"),"valid new unicast MAC retained even when ICMP is blocked");
  Check(!merged.Any(x=>x.Ip=="10.0.0.3")&&!merged.Any(x=>x.Ip=="10.0.0.6")&&!merged.Any(x=>x.Ip=="10.0.1.2"),"new failed zero-MAC wrong-interface and out-of-scope rows excluded");
  Check(merged.Single(x=>x.Ip=="10.0.0.4").Name=="人工名称"&&merged.Single(x=>x.Ip=="10.0.0.4").ReportedName=="network-name","existing reported/manual names preserved during cache refresh");
  Check(merged.Single(x=>x.Ip=="10.0.0.4").Source==named.Source&&merged.Single(x=>x.Ip=="10.0.0.4").State.Contains("本次ICMP回应"),"original interface source preserved with separate reply evidence");
  Check(named.State=="缓存"&&old.State=="缓存","merge never mutates input observations");
  var changedMac=Row("10.0.0.4","00:11:22:33:44:99",named.Source);
  var changed=DiscoveryRunner.MergeDevices(plan,new[]{named},new[]{changedMac},new string[0],DateTime.UtcNow);
  Check(changed.Count==1&&changed[0].Name=="未知"&&String.IsNullOrEmpty(changed[0].NameSource)&&changed[0].Mac==changedMac.Mac,"DHCP reuse with changed MAC cannot inherit old confirmed identity");
  var unknownPrior=Row("10.0.0.4","未知",named.Source);unknownPrior.Name="stale-name";unknownPrior.NameSource=DeviceIdentity.NetworkNameSource;
  changed=DiscoveryRunner.MergeDevices(plan,new[]{unknownPrior},new[]{changedMac},new string[0],DateTime.UtcNow);
  Check(changed[0].Name=="未知","unknown previous MAC never establishes identity continuity");
  using(var cancel=new CancellationTokenSource()){
   int started=0,finished=0;
   runner=new DiscoveryRunner(address=>true,async(address,timeout,token,sent)=>{sent();Interlocked.Increment(ref started);try{await Task.Delay(2000,token);}catch(OperationCanceledException){}finally{Interlocked.Increment(ref finished);}return DiscoveryProbeOutcome.NoReply;},token=>Task.FromResult(new List<DeviceInfo>()),5000);
   cancel.CancelAfter(50);var watch=Stopwatch.StartNew();result=await runner.RunAsync(plan,new List<DeviceInfo>(),watch,cancel.Token);
   await Task.Delay(50);
   Check(result.Cancelled&&watch.ElapsedMilliseconds<600&&started<=8&&started==finished,"cancellation is bounded and fake operations settle");
  }
  var completions=new List<TaskCompletionSource<DiscoveryProbeOutcome>>();
  runner=new DiscoveryRunner(address=>true,(address,timeout,token,sent)=>{sent();var t=new TaskCompletionSource<DiscoveryProbeOutcome>();lock(completions)completions.Add(t);return t.Task;},token=>Task.FromResult(new List<DeviceInfo>()),300);
  var deadlineWatch=Stopwatch.StartNew();result=await runner.RunAsync(plan,new List<DeviceInfo>(),deadlineWatch,CancellationToken.None);
  Check(deadlineWatch.ElapsedMilliseconds<700&&completions.Count<=8&&result.Replied==0,"noncooperative fake transport cannot expand indefinitely or exceed UI deadline");
  foreach(var completion in completions)completion.TrySetResult(DiscoveryProbeOutcome.NoReply);
  using(var cancel=new CancellationTokenSource()){
   var waitingRunner=new DiscoveryRunner(address=>true,async(address,timeout,token,sent)=>{
    try{await Task.Delay(2000,token);}catch(OperationCanceledException){}return DiscoveryProbeOutcome.Skipped;
   },token=>Task.FromResult(new List<DeviceInfo>()),5000);
   cancel.CancelAfter(30);result=await waitingRunner.RunAsync(plan,new List<DeviceInfo>(),Stopwatch.StartNew(),cancel.Token);
   Check(result.Cancelled&&result.Attempted==0&&result.Skipped==plan.Targets.Count,"cancel while waiting native slots does not count unsent addresses");
  }
  int cacheCalls=0;var cachePending=new TaskCompletionSource<List<DeviceInfo>>();
  var cacheReader=new DiscoveryCacheReader(()=>{Interlocked.Increment(ref cacheCalls);return cachePending.Task;});
  for(int round=0;round<5;round++){
   using(var cancelled=new CancellationTokenSource()){
    cancelled.CancelAfter(5);
    var waiting=Enumerable.Range(0,4).Select(x=>cacheReader.ReadAsync(20,cancelled.Token)).ToArray();
    await Task.WhenAll(waiting);
   }
  }
  Check(cacheCalls==1,"hung cache shared across repeated cancelled batches rather than accumulating reads");
  cachePending.SetResult(new List<DeviceInfo>{old});
  await cacheReader.ReadAsync(100,CancellationToken.None);
  Check(cacheCalls==2,"cache read ownership released only after actual completion");
  using(var cancel=new CancellationTokenSource()){
   cancel.Cancel();result=await runner.RunAsync(plan,new List<DeviceInfo>{old},Stopwatch.StartNew(),cancel.Token);
   Check(result.Cancelled&&result.Attempted==0&&result.Devices.Count==1,"pre-cancel sends nothing and preserves records");
  }
 }
}
