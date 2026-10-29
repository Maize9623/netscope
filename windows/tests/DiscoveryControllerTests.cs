using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Reflection;
using System.Threading;
using NetScope;
class DiscoveryControllerTests {
 static int checks;
 static void Check(bool ok,string message){if(!ok)throw new Exception(message);checks++;Console.WriteLine("PASS "+message);}
 static List<DeviceInfo> Merge(List<DeviceInfo> before,List<DeviceInfo> after){
  return (List<DeviceInfo>)typeof(AppController).GetMethod("MergeDeviceSnapshot",BindingFlags.Static|BindingFlags.NonPublic).Invoke(null,new object[]{before,after});
 }
 static DeviceInfo Row(string mac){return new DeviceInfo{Ip="10.0.0.2",Mac=mac,Source="Windows 邻居缓存；接口 7",Name="未知",Hint="原始"};
 }
 static void Main(){
  var old=Row("00:11:22:33:44:55");old.ReportedName="reported";old.ReportedNameSource=DeviceIdentity.NetworkNameSource;old.ReportedHint="raw type";
  var rows=Merge(new List<DeviceInfo>{old},new List<DeviceInfo>{Row("00-11-22-33-44-55")});
  Check(rows[0].ReportedName=="reported"&&rows[0].NameSource==DeviceIdentity.NetworkNameSource,"canonical same MAC preserves network name");
  rows=Merge(new List<DeviceInfo>{old},new List<DeviceInfo>{Row("00:11:22:33:44:66")});
  Check(rows[0].Name=="未知"&&rows[0].ReportedName==null,"changed MAC cannot inherit controller identity");
  var unknown=Row("未知");unknown.ReportedName="stale";unknown.ReportedNameSource=DeviceIdentity.NetworkNameSource;
  rows=Merge(new List<DeviceInfo>{unknown},new List<DeviceInfo>{Row("未知")});
  Check(rows[0].ReportedName==null,"two unknown MACs do not prove same device");
  var other=Row(old.Mac);other.Source="Windows 邻居缓存；接口 8";
  rows=Merge(new List<DeviceInfo>{old},new List<DeviceInfo>{other});
  Check(rows[0].ReportedName==null,"same IP MAC on different interface does not inherit source");
  var fresh=Row(old.Mac);fresh.ReportedName="new report";fresh.ReportedNameSource="new source";
  rows=Merge(new List<DeviceInfo>{old},new List<DeviceInfo>{fresh});
  Check(rows[0].ReportedName=="new report","new supplied source is not overwritten");
  var reply=Row("未知");reply.Source="用户触发的有限 ICMP 回应；接口 7";reply.ObservedAt=DateTime.UtcNow;
  rows=Merge(new List<DeviceInfo>{reply},new List<DeviceInfo>());
  Check(rows.Count==1,"recent confirmed ICMP evidence survives a passive refresh");
  reply.ObservedAt=DateTime.UtcNow.AddMinutes(-11);rows=Merge(new List<DeviceInfo>{reply},new List<DeviceInfo>());
  Check(rows.Count==0,"old reply-only evidence expires after ten minutes");
  Check(old.Name=="未知"&&fresh.Name=="未知","controller merge does not mutate input snapshots");
  string root=Path.Combine(Path.GetTempPath(),"NetScope-DiscoveryController-"+Guid.NewGuid().ToString("N"));
  Directory.CreateDirectory(root);
  try{
   var settings=Defaults.Create();settings.AutoMonitor=false;settings.AiAutoEnabled=false;settings.MaxAiCallsPerDay=0;settings.CodexPath=Path.Combine(root,"no-codex.exe");
   new Store(root).SaveSettings(settings);
   using(var controller=new AppController(root)){
    Check(!controller.IsDeviceDiscovering&&controller.Devices.Count==0,"controller construction does not start discovery");
    var cancellation=new CancellationTokenSource();
    typeof(AppController).GetField("deviceDiscoveryCancellation",BindingFlags.Instance|BindingFlags.NonPublic).SetValue(controller,cancellation);
    controller.CancelDeviceDiscovery();Check(cancellation.IsCancellationRequested,"explicit cancel cancels active discovery token");
    typeof(AppController).GetField("deviceDiscoveryCancellation",BindingFlags.Instance|BindingFlags.NonPublic).SetValue(controller,null);cancellation.Dispose();
    cancellation=new CancellationTokenSource();
    typeof(AppController).GetField("deviceDiscoveryCancellation",BindingFlags.Instance|BindingFlags.NonPublic).SetValue(controller,cancellation);
    bool closedBeforeCancel=false;
    var registration=cancellation.Token.Register(()=>closedBeforeCancel=(bool)typeof(AppController).GetField("disposed",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(controller));
    controller.Dispose();Check(cancellation.IsCancellationRequested&&closedBeforeCancel,"controller closes registration before cancellation to prevent dispose race");
    registration.Dispose();typeof(AppController).GetField("deviceDiscoveryCancellation",BindingFlags.Instance|BindingFlags.NonPublic).SetValue(controller,null);cancellation.Dispose();
    Check(controller.AiCallsToday==0&&controller.CurrentFrame==null,"merge and cancellation checks invoke no AI or HTTP probe");
   }
   string retention=Path.Combine(root,"retention");var store=new Store(retention);
   string oldDate=DateTime.UtcNow.AddDays(-8).ToString("yyyy-MM-dd"),recentDate=DateTime.UtcNow.AddDays(-1).ToString("yyyy-MM-dd"),futureDate=DateTime.UtcNow.AddDays(1).ToString("yyyy-MM-dd");
   foreach(string prefix in new[]{"device-discovery-","ai-device-"}){
    File.WriteAllText(Path.Combine(retention,prefix+oldDate+".jsonl"),"old");
    File.WriteAllText(Path.Combine(retention,prefix+recentDate+".jsonl"),"recent");
    File.WriteAllText(Path.Combine(retention,prefix+futureDate+".jsonl"),"future");
    File.WriteAllText(Path.Combine(retention,prefix+"not-a-date.jsonl"),"invalid");
   }
   File.WriteAllText(Path.Combine(retention,"unrelated-"+oldDate+".jsonl"),"unrelated");
   store.Prune(7);
   Check(new[]{"device-discovery-","ai-device-"}.All(p=>!File.Exists(Path.Combine(retention,p+oldDate+".jsonl"))),"expired discovery and device-AI history follow retention");
   Check(new[]{"device-discovery-","ai-device-"}.All(p=>File.Exists(Path.Combine(retention,p+recentDate+".jsonl"))&&File.Exists(Path.Combine(retention,p+futureDate+".jsonl"))),"recent and future history is retained");
   Check(File.Exists(Path.Combine(retention,"unrelated-"+oldDate+".jsonl"))&&new[]{"device-discovery-","ai-device-"}.All(p=>File.Exists(Path.Combine(retention,p+"not-a-date.jsonl"))),"unrelated and invalid-date files are never pruned");
  }finally{Directory.Delete(root,true);}
  Console.WriteLine("RESULT "+checks+" discovery controller checks passed; pure merge/token checks, no LAN discovery.");
 }
}
