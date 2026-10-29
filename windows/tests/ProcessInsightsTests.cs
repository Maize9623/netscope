using System;
using System.Linq;
using System.Collections.Generic;
using NetScope;
class ProcessInsightsTests {
 static DateTime now=new DateTime(2026,10,29,12,0,0,DateTimeKind.Utc);static int count;
 static ProcessTrafficRow R(double down,double up=0,int pid=100,string name="browser",string instance="start-1"){return new ProcessTrafficRow{Pid=pid,Name=name,InstanceId=instance,DownloadBps=down,UploadBps=up,ReceivedBytes=(long)(down*2),SentBytes=(long)(up*2),ObservedSharePercent=90,Note=""};}
 static ProcessTrafficSnapshot S(int ago,params ProcessTrafficRow[] rows){return new ProcessTrafficSnapshot{At=now.AddSeconds(-ago),IntervalSeconds=2,State="Running",LostEvents=0,IsPartial=false,Measurement="Synthetic ETW event bytes",Processes=rows.ToList(),EventCount=1};}
 static List<ProcessTrafficSnapshot> Baseline(int n=10,double rate=10*1024){return Enumerable.Range(1,n).Select(i=>S(i*2,R(rate))).ToList();}
 static bool Has(List<Finding> findings,string key){return findings.Any(f=>f.Key.StartsWith(key,StringComparison.Ordinal));}
 static void Check(bool condition,string name){if(!condition)throw new Exception(name);count++;Console.WriteLine("PASS "+name);}
 static List<Finding> E(ProcessTrafficSnapshot current,List<ProcessTrafficSnapshot> history=null){return ProcessInsights.Evaluate(current,history??new List<ProcessTrafficSnapshot>());}
 static int Main(){
  Check(E(null).Count==0,"null capture is unknown, not zero traffic");Check(E(S(0,R(1024*1024))).Count==0,"cold start does not label a burst");
  var h=Baseline();Check(!Has(E(S(0,R(1024*1024)),h),"process:increase:"),"one high sample cannot establish burst");h[0]=S(2,R(1024*1024));var x=E(S(0,R(1024*1024)),h);Check(Has(x,"process:increase:"),"two high samples with ten baseline observations detected");Check(x.First(f=>f.Key.StartsWith("process:increase:")).Evidence.Contains("5 倍")&&x[0].Evidence.Contains("256 KiB/s")&&x[0].Evidence.Contains("可能重复计量"),"burst evidence includes thresholds and duplicate accounting limit");Check(x[0].Advice.Contains("不代表恶意")&&x[0].Advice.Contains("不能证明"),"burst does not claim maliciousness or link saturation");
  h=Baseline(9);h[0]=S(2,R(1024*1024));Check(!Has(E(S(0,R(1024*1024)),h),"process:increase:"),"minimum ten baseline observations required");
  h=Baseline();h[0]=S(2,R(256*1024));Check(!Has(E(S(0,R(256*1024)),h),"process:increase:"),"exact 256 KiB boundary is not above floor");
  h=Baseline(10,100*1024);h[0]=S(2,R(500*1024));Check(!Has(E(S(0,R(500*1024)),h),"process:increase:"),"exact five times median is not above threshold");
  h=Baseline(10,600*1024);Check(!Has(E(S(0,R(600*1024)),h),"process:increase:"),"normal steady high throughput not labeled increase");
  h=Baseline();h[0]=S(2,R(1024*1024));Check(!Has(E(S(0,R(1024*1024,0,100,"other-name")),h),"process:increase:"),"PID name change isolates identity");Check(!Has(E(S(0,R(1024*1024,0,100,"browser","new-start")),h),"process:increase:"),"process start identity isolates reused PID");
  h=Baseline();h[0]=S(12,R(1024*1024));h=h.Where(s=>(now-s.At).TotalSeconds>=12).ToList();for(int i=0;i<10;i++)h.Add(S(30+i*2,R(10*1024)));Check(!Has(E(S(0,R(1024*1024)),h),"process:increase:"),"more than ten seconds between current samples breaks continuity");
  foreach(string state in new[]{"Skipped","Stale","Error","Stopped","PermissionRequired"}){var s=S(0,R(1024*1024));s.State=state;Check(E(s,Baseline()).Count==0,state+" is not a process anomaly");}
  var lost=S(0,R(1024*1024));lost.LostEvents=3;x=E(lost,Baseline());Check(x.Count==1&&x[0].Severity=="info"&&x[0].Key=="process:incomplete","lost events only report incomplete measurement");lost=S(0,R(1024*1024));lost.IsPartial=true;Check(!Has(E(lost,Baseline()),"process:increase:"),"partial samples cannot establish process increase");
  var invalid=S(0,R(1024*1024));invalid.IntervalSeconds=0;Check(E(invalid,Baseline()).Count==0,"invalid interval ignored");invalid.IntervalSeconds=11;Check(E(invalid,Baseline()).Count==0,"overlong sample interval ignored");
  h=Enumerable.Range(1,4).Select(i=>S(i*2,R(0,129*1024))).ToList();x=E(S(0,R(0,129*1024)),h);Check(x.Any(f=>f.Key.StartsWith("process:upload:")&&f.Severity=="info"),"five positive upload observations recorded as info");Check(x[0].Advice.Contains("合法")&&x[0].Advice.Contains("不是恶意"),"upload explicitly permits normal synchronization");Check(!Has(E(S(0,R(0,128*1024)),h),"process:upload:"),"exact upload threshold not exceeded");
  h=Enumerable.Range(1,3).Select(i=>S(i*2,R(0,129*1024))).ToList();Check(!Has(E(S(0,R(0,129*1024)),h),"process:upload:"),"fewer than five upload observations insufficient");
  h=Enumerable.Range(1,5).Select(i=>S(i*2,R(0,129*1024))).ToList();h[1]=S(4);Check(!Has(E(S(0,R(0,129*1024)),h),"process:upload:"),"missing process observation breaks upload continuity");h[1]=S(4,R(0,129*1024));h[1].State="Error";Check(!Has(E(S(0,R(0,129*1024)),h),"process:upload:"),"failed capture breaks upload continuity");
  h=Baseline();h[0]=S(2,R(1024*1024));var app=R(1024*1024);var vpn=R(1024*1024,0,200,"vpn","start-vpn");x=E(S(0,app,vpn),h);Check(x.Count(f=>f.Key.StartsWith("process:increase:"))==1,"VPN bytes not summed into another process baseline");
  h=Enumerable.Range(1,4).Select(i=>S(i*2,R(0,129*1024))).ToList();var duplicate=R(0,129*1024);Check(!Has(E(S(0,duplicate,duplicate),h),"process:upload:"),"duplicate identity rows not double-counted");
  h=Baseline();h[0]=S(2,R(1024*1024));var zeroIdentity=R(1024*1024,0,0);Check(E(S(0,zeroIdentity),h).Count==0,"unknown zero PID is not attributed");var nan=R(0);nan.DownloadBps=Double.NaN;Check(E(S(0,nan),h).Count==0,"invalid rate not a process anomaly");
  h=Baseline();h[0]=S(2,R(1024*1024));string key1=E(S(0,R(1024*1024)),h).First(f=>f.Key.StartsWith("process:increase:")).Key;string key2=E(S(0,R(1024*1024)),h).First(f=>f.Key.StartsWith("process:increase:")).Key;Check(key1==key2,"event keys stable for cooldown");
  Console.WriteLine("RESULT "+count+" process insight checks passed. Synthetic event-byte samples only.");return 0;
 }
}

