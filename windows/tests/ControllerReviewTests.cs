using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Collections.Generic;
using NetScope;
public class ControllerReviewTests {
 static int pass,fail;
 static DateTime now=DateTime.UtcNow;
 static string root=Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"controller-review-data-"+DateTime.UtcNow.ToString("yyyyMMddHHmmss"));
 static string NewDir(string name){string p=Path.Combine(root,name);Directory.CreateDirectory(p);return p;}
 static ProbeResult Probe(string id,string name,string url,DateTime at,int? code,double? latency){return new ProbeResult{TargetId=id,Name=name,Url=url,At=at,Group="AI",StatusCode=code,Reachable=code.HasValue,HttpMs=latency,DnsMs=2,TcpMs=10,Outcome=code.HasValue?"OK":"Timeout"};}
 static void Check(bool ok,string reason){if(!ok)throw new Exception(reason);}
 static void Test(string name,Action body){try{body();pass++;Console.WriteLine("PASS "+name);}catch(Exception e){fail++;Console.WriteLine("FAIL "+name+" :: "+e.Message);}}
 static AppController Controller(string name,AppSettings s,params HistoryPoint[] points){var store=new Store(NewDir(name));store.SaveSettings(s);foreach(var p in points)store.Append("history",p);return new AppController(store.DirectoryPath);}
 static HistoryPoint Point(params ProbeResult[] probes){return new HistoryPoint{At=probes.Min(p=>p.At),DownloadBps=10,UploadBps=20,Probes=probes.ToList()};}
 public static int Main(){
 Test("anonymized report contains no private fields",()=>{
  var s=Defaults.Create();s.Targets.Add(new ProbeTarget{Id="TENANT_SECRET_847",Name="INTERNAL_PROJECT_SECRET_521",Group="DEPARTMENT_SECRET_193",Url="https://private-secret.example/secret-path?token=URL_TOKEN_SECRET_836",Enabled=true});
  var p=Probe(s.Targets.Last().Id,s.Targets.Last().Name,s.Targets.Last().Url,now.AddSeconds(-30),200,125);p.Group=s.Targets.Last().Group;p.Address="10.123.45.67";p.Route="http://private-proxy-secret.example:7890";p.Error="ERROR_SECRET_290 device AA:BB:CC:DD:EE:FF";
  using(var c=Controller("privacy",s,Point(p))){string report=c.BuildReport(true);foreach(string secret in new[]{"TENANT_SECRET_847","INTERNAL_PROJECT_SECRET_521","DEPARTMENT_SECRET_193","private-secret.example","URL_TOKEN_SECRET_836","10.123.45.67","private-proxy-secret.example","ERROR_SECRET_290","AA:BB:CC:DD:EE:FF"})Check(!report.Contains(secret),"leaked: "+secret);Check(report.Contains("125.0"),"lost useful measurement");}
 });
 Test("historical URL changes remain separate after anonymization",()=>{
  var old=Probe("openai","OLD_PRIVATE_NAME_107","https://old-private.example/api",now.AddSeconds(-90),null,null);
  var current=Probe("openai","OpenAI API","https://api.openai.com/v1/models",now.AddSeconds(-30),401,100);
  using(var c=Controller("url-history",Defaults.Create(),Point(old),Point(current))){string report=c.BuildReport(true);Check(!report.Contains("OLD_PRIVATE_NAME_107")&&!report.Contains("old-private.example"),"old target leaked");Check(report.Split(new[]{"1 次有效配置探测"},StringSplitOptions.None).Length-1==2,"different target URLs merged");Check(!report.Contains("2 次有效配置探测"),"different URL samples merged");Check(report.Contains("OpenAI API"),"known public target label missing");}
 });
 Test("local report preserves historical target identity",()=>{
  var old=Probe("openai","OLD_TARGET_LABEL","https://old-private.example/api",now.AddSeconds(-90),null,null);
  var current=Probe("openai","NEW_TARGET_LABEL","https://api.openai.com/v1/models",now.AddSeconds(-30),401,100);
  using(var c=Controller("local-history",Defaults.Create(),Point(old),Point(current))){string report=c.BuildReport(false);Check(report.Contains("OLD_TARGET_LABEL")&&report.Contains("NEW_TARGET_LABEL"),"historical names overwritten by current settings");Check(!report.Contains("2 次有效配置探测"),"URL boundary merged in local report");}
 });
 Test("anonymized target alias is stable across reports",()=>{
  var s=Defaults.Create();s.Targets.Add(new ProbeTarget{Id="cust",Name="PrivateDisplay",Group="自定义",Url="https://private.example/",Enabled=true});
  using(var c=Controller("stable-alias",s,Point(Probe("cust","PrivateDisplay","https://private.example/",now.AddSeconds(-30),200,100)))){string r1=c.BuildReport(true),r2=c.BuildReport(true);string first=r1.Split('\n').First(x=>x.Contains("1 次有效配置探测")),second=r2.Split('\n').First(x=>x.Contains("1 次有效配置探测"));Check(first==second,"unstable alias");}
 });
 Test("paused gaps and missing results do not become failures",()=>{
  var good=Point(Probe("openai","OpenAI API","https://api.openai.com/v1/models",now.AddHours(-2),401,100));
  var traffic=new HistoryPoint{At=now.AddMinutes(-30),DownloadBps=0,UploadBps=0};
  using(var c=Controller("missing-data",Defaults.Create(),good,traffic)){string report=c.BuildReport(true);Check(report.Contains("100.0%（1/1）"),"missing rounds turned into failures");Check(report.Contains("1 次有效配置探测"),"traffic counted as target probe");}
 });
 Test("repeated same probe snapshot counted once",()=>{
  var p=Probe("openai","OpenAI API","https://api.openai.com/v1/models",now.AddMinutes(-1),401,100);
  var h1=Point(p);var h2=Point(p);h2.At=now.AddSeconds(-30);
  using(var c=Controller("duplicates",Defaults.Create(),h1,h2)){string report=c.BuildReport(true);Check(report.Contains("1 次有效配置探测"),"duplicate result counted twice");}
 });
 Test("CSV formula names are neutralized",()=>{
  var p=Probe("x","=HYPERLINK(\"https://bad.example\")","https://x.example",now.AddMinutes(-1),200,50);
  using(var c=Controller("csv-formula",Defaults.Create(),Point(p))){string path=Path.Combine(c.DataDirectory,"out.csv");c.ExportHistoryCsv(path,TimeSpan.FromHours(24));string csv=File.ReadAllText(path);Check(csv.Contains("\"'=HYPERLINK"),"formula not prefixed as text");Check(csv.Contains("\"\"https://bad.example\"\""),"quotes not escaped");}
 });
 Test("CSV whitespace-prefixed formulas are neutralized",()=>{
  var p=Probe("x","\t=1+1","https://x.example",now.AddMinutes(-1),200,50);
  using(var c=Controller("csv-tab-formula",Defaults.Create(),Point(p))){string path=Path.Combine(c.DataDirectory,"out.csv");c.ExportHistoryCsv(path,TimeSpan.FromHours(24));string csv=File.ReadAllText(path);Check(!csv.Contains(",\"\t=1+1\","),"tab-prefixed formula exported without neutralization");}
 });
 Console.WriteLine("RESULT "+pass+" passed, "+fail+" failed");return fail==0?0:1;
 }
}
