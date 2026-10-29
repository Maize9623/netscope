using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using NetScope;
class DeviceIdentityTests {
 static int checks;
 static void Check(bool valid,string message){if(!valid)throw new Exception(message);checks++;Console.WriteLine("PASS "+message);}
 static DeviceInfo Row(int n){return new DeviceInfo{Ip="192.0.2."+n,Mac="00:11:22:33:44:"+n,Name="未知",Hint="设备类型未知",State="缓存",Source="Windows 邻居缓存；接口 8"};}
 static void Main(){Run().GetAwaiter().GetResult();Console.WriteLine(checks+" checks passed; injected resolver only; no DNS requests.");}
 static async Task Run(){
  var input=Row(1);int calls=0;
  var resolver=new DeviceNameResolver(ip=>{calls++;return Task.FromResult("test-device.example.");},100);
  var result=await resolver.ResolveNamesAsync(new List<DeviceInfo>{input});
  Check(result[0].Name=="test-device.example","network name normalized");
  Check(result[0].NameSource==DeviceIdentity.NetworkNameSource&&result[0].ReportedNameSource==DeviceIdentity.NetworkNameSource,"unverified network source explicit");
  Check(result[0].ReportedName=="test-device.example","raw reported name recorded");
  Check(result[0].Source==input.Source&&result[0].Hint==input.Hint&&result[0].State==input.State,"original cache evidence preserved");
  Check(input.Name=="未知"&&input.ReportedName==null,"input remains unchanged");
  await resolver.ResolveNamesAsync(new List<DeviceInfo>{input});
  Check(calls==1,"successful resolution cached");
  var reused=Row(1);reused.Mac="different";
  await resolver.ResolveNamesAsync(new List<DeviceInfo>{reused});
  Check(calls==2,"different observed MAC does not inherit cached name");
  var manual=Row(2);manual.Name="我的设备";manual.NameSource="人工确认 / 本地标签";
  result=await resolver.ResolveNamesAsync(new List<DeviceInfo>{manual});
  Check(result[0].Name=="我的设备"&&result[0].NameSource==manual.NameSource,"manual display label preserved");
  Check(result[0].ReportedName=="test-device.example"&&result[0].ReportedNameSource==DeviceIdentity.NetworkNameSource,"manual label keeps separately reported network name");
  IPAddress ignored;
  var self=Row(3);self.Source="本机接口 / Windows 自报";
  Check(!DeviceNameResolver.Eligible(self,out ignored),"own device not sent to DNS");
  var imported=Row(4);imported.Source="网关导入快照";
  Check(!DeviceNameResolver.Eligible(imported,out ignored),"imported history not actively queried");
  foreach(var ip in new[]{"127.0.0.1","0.0.0.0","255.255.255.255","224.0.0.1","::1","::","ff02::1","not-an-ip"}){
   var row=Row(5);row.Ip=ip;Check(!DeviceNameResolver.Eligible(row,out ignored),"exclude non-neighbor "+ip);
  }
  Check(DeviceNameResolver.CleanName("192.0.2.1")==null&&DeviceNameResolver.CleanName(" ")==null,"numeric and empty responses stay unknown");
  Check(DeviceNameResolver.CleanName("host\nname")==null&&DeviceNameResolver.CleanName("host\u202ename")==null,"control characters and bidi injection rejected");
  var failure=new DeviceNameResolver(ip=>Task.FromResult<string>(null),10);
  result=await failure.ResolveNamesAsync(new List<DeviceInfo>{Row(1)});
  Check(result[0].Name=="未知"&&result[0].ReportedName==null,"no name is not fabricated");
  int manyCalls=0;
  var limited=new DeviceNameResolver(ip=>{manyCalls++;return Task.FromResult("device.example");},10);
  var forty=Enumerable.Range(1,40).Select(Row).ToList();
  result=await limited.ResolveNamesAsync(forty);
  Check(manyCalls==32&&result.Count==40&&result.Skip(32).All(x=>x.Name=="未知"),"only first 32 known devices queried");
  var pending=new List<TaskCompletionSource<string>>();int active=0,maximum=0;
  var bounded=new DeviceNameResolver(ip=>{
   Interlocked.Increment(ref active);maximum=Math.Max(maximum,active);
   var t=new TaskCompletionSource<string>();pending.Add(t);
   return t.Task;
  },40);
  var timer=Stopwatch.StartNew();
  result=await bounded.ResolveNamesAsync(forty);
  Check(timer.ElapsedMilliseconds<1000&&result.All(x=>x.Name=="未知"),"unresponsive native queries have bounded UI deadline");
  Check(pending.Count==2&&bounded.PendingCount==2&&maximum==2,"at most two underlying DNS operations survive timeout");
  await bounded.ResolveNamesAsync(forty);
  Check(pending.Count==2&&bounded.PendingCount==2,"repeated clicks do not accumulate abandoned DNS work");
  pending[0].SetResult("late-name.example");pending[1].SetResult(null);
  Check(bounded.PendingCount==0,"pending positions released only on actual completion");
  result=await bounded.ResolveNamesAsync(new List<DeviceInfo>{Row(1)});
  Check(result[0].Name=="late-name.example","late result can be reused through bounded cache");
  var cacheBound=new DeviceNameResolver(ip=>Task.FromResult("cached.example"),10);
  for(int n=0;n<300;n++){var row=Row(1);row.Mac=n.ToString();await cacheBound.ResolveNamesAsync(new List<DeviceInfo>{row});}
  Check(cacheBound.CacheCount<=256,"name cache is bounded");
  int duplicated=0;
  var dedupe=new DeviceNameResolver(ip=>{duplicated++;return Task.FromResult("same.example");},10);
  result=await dedupe.ResolveNamesAsync(new List<DeviceInfo>{Row(1),Row(1)});
  Check(duplicated==1&&result.All(x=>x.Name=="same.example"),"duplicate cache rows resolve once");
 }
}
