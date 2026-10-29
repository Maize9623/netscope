using System;
using System.IO;
using System.Text;
using System.Linq;
using System.Diagnostics;
using System.Globalization;
using System.Collections;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace NetScope {
 public class QuotaWindow {
  public string Name {get;set;}
  public double UsedPercent {get;set;}
  public double RemainingPercent {get;set;}
  public DateTime? ResetAt {get;set;}
  public int? WindowMinutes {get;set;}
 }
 public class QuotaSnapshot {
  public DateTime At {get;set;}
  public List<QuotaWindow> Windows {get;set;}
  public string Plan {get;set;}
  public string CreditBalance {get;set;}
  public bool? HasCredits {get;set;}
  public bool? UnlimitedCredits {get;set;}
  public int? ResetCreditsAvailable {get;set;}
  public DateTime? ResetCreditExpiresAt {get;set;}
  public string Status {get;set;}
  public string Error {get;set;}
  public QuotaSnapshot(){At=DateTime.UtcNow;Windows=new List<QuotaWindow>();}
 }
 public static class QuotaClient {
  static readonly object Sync=new object();
  static Task<QuotaSnapshot> pending;
  // No model request is issued. Concurrent callers share the same bounded read.
  public static Task<QuotaSnapshot> ReadAsync(string codexPath){lock(Sync){if(pending!=null&&!pending.IsCompleted)return pending;pending=Task.Run(()=>ReadCoreAsync(codexPath));return pending;}}
  static async Task<QuotaSnapshot> ReadCoreAsync(string codexPath){
   var snapshot=new QuotaSnapshot{Status="查询未完成"};
   if(String.IsNullOrWhiteSpace(codexPath)||!Path.IsPathRooted(codexPath)||!File.Exists(codexPath)){snapshot.Error="未找到 Codex CLI；请设置本机 codex.exe 的绝对路径。";snapshot.Status="无法查询";return snapshot;}
   DateTime deadline=DateTime.UtcNow.AddSeconds(18);
   var init=new TaskCompletionSource<Dictionary<string,object>>();
   var result=new TaskCompletionSource<Dictionary<string,object>>();
   using(var child=new Process()){
    child.StartInfo=new ProcessStartInfo(codexPath,"app-server --stdio -c analytics.enabled=false"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,StandardOutputEncoding=Encoding.UTF8,StandardErrorEncoding=Encoding.UTF8,WorkingDirectory=Path.GetDirectoryName(codexPath)};
    // Drain and discard stderr; auth diagnostics can contain identifying data.
    child.ErrorDataReceived+=(sender,e)=>{};
    child.OutputDataReceived+=(sender,e)=>{
     if(String.IsNullOrWhiteSpace(e.Data)||e.Data.Length>1048576||e.Data[0]!='{')return;
     try{var response=ParseObject(e.Data);if(response==null||!response.ContainsKey("id"))return;int? id=Int(response,"id");if(response.ContainsKey("method"))return;if(id==1)init.TrySetResult(response);else if(id==2)result.TrySetResult(response);}catch{}
    };
    bool started=false;
    try{
     child.Start();started=true;child.BeginOutputReadLine();child.BeginErrorReadLine();
     Write(child,new Dictionary<string,object>{{"id",1},{"method","initialize"},{"params",new{clientInfo=new{name="netscope",version="0.1.0"},capabilities=new{experimentalApi=true,explicitGatewayOauth=true}}}});
     RequireResult(await BeforeDeadline(init.Task,deadline));
     Write(child,new Dictionary<string,object>{{"method","initialized"},{"params",new Dictionary<string,object>()}});
     Write(child,new Dictionary<string,object>{{"id",2},{"method","account/rateLimits/read"},{"params",new{excludeResetCreditDetails=false}}});
     snapshot=ParseSnapshot(RequireResult(await BeforeDeadline(result.Task,deadline)));
     snapshot.At=DateTime.UtcNow;
    }catch(TimeoutException){snapshot.Status="查询超时";snapshot.Error="额度查询超过 18 秒；请检查 Codex 登录、代理和网络。未调用模型，也未消耗重置机会。";}
    catch(QuotaProtocolException e){snapshot.Status="接口未返回额度";snapshot.Error=e.Message;}
    catch(Exception){snapshot.Status="无法查询";snapshot.Error="无法完成 Codex 额度只读查询；请检查 CLI 版本、登录状态和网络。没有读取或显示认证文件。";}
    finally{
     if(started){try{child.StandardInput.Close();}catch{}try{if(!child.WaitForExit(400))child.Kill();}catch{}}
    }
   }
   return snapshot;
  }
  static async Task<Dictionary<string,object>> BeforeDeadline(Task<Dictionary<string,object>> response,DateTime deadline){int remain=(int)Math.Max(1,(deadline-DateTime.UtcNow).TotalMilliseconds);if(await Task.WhenAny(response,Task.Delay(remain))!=response)throw new TimeoutException();return await response;}
  static void Write(Process child,object value){byte[] bytes=new UTF8Encoding(false).GetBytes(Json(value)+"\n");child.StandardInput.BaseStream.Write(bytes,0,bytes.Length);child.StandardInput.BaseStream.Flush();}
  static Dictionary<string,object> RequireResult(Dictionary<string,object> response){
   if(response==null)throw new QuotaProtocolException("Codex 返回空协议响应。");
   var err=Object(response,"error");if(err!=null){int? code=Int(err,"code");throw new QuotaProtocolException("Codex 额度接口返回错误"+(code.HasValue?"（代码 "+code.Value.ToString(CultureInfo.InvariantCulture)+"）":"")+"；请检查登录、网络或 CLI 版本。");}
   var result=Object(response,"result");if(result==null)throw new QuotaProtocolException("Codex 没有返回可解析的额度对象。");return result;
  }
  // Only selected quota fields leave this parser. Account IDs and opaque credit IDs are discarded.
  internal static QuotaSnapshot ParseSnapshot(Dictionary<string,object> root){
   var q=new QuotaSnapshot{Status="已更新：账号共享额度（只读）"};
   var map=Object(root,"rateLimitsByLimitId");
   var buckets=new List<KeyValuePair<string,Dictionary<string,object>>>();
   if(map!=null)foreach(var item in map){var obj=item.Value as Dictionary<string,object>;if(obj!=null)buckets.Add(new KeyValuePair<string,Dictionary<string,object>>(item.Key,obj));}
   if(buckets.Count==0){var legacy=Object(root,"rateLimits");if(legacy!=null)buckets.Add(new KeyValuePair<string,Dictionary<string,object>>(Text(legacy,"limitId")??"codex",legacy));}
   foreach(var item in buckets.OrderBy(x=>x.Key=="codex"?0:1).ThenBy(x=>x.Key,StringComparer.Ordinal)){
    var bucket=item.Value;
    string label=Text(bucket,"limitName")??Text(bucket,"normalModelSlug")??Text(bucket,"limitId")??item.Key;
    if(String.Equals(label,"codex",StringComparison.OrdinalIgnoreCase))label="Codex";
    AddWindow(q,label,Object(bucket,"primary"),"主窗口");AddWindow(q,label,Object(bucket,"secondary"),"次窗口");
    if(q.Plan==null)q.Plan=Text(bucket,"planType");
    var credit=Object(bucket,"credits");if(credit!=null){if(!q.HasCredits.HasValue)q.HasCredits=Bool(credit,"hasCredits");if(!q.UnlimitedCredits.HasValue)q.UnlimitedCredits=Bool(credit,"unlimited");if(q.CreditBalance==null)q.CreditBalance=Text(credit,"balance");}
   }
   var resets=Object(root,"rateLimitResetCredits");if(resets!=null){q.ResetCreditsAvailable=Int(resets,"availableCount");if(q.ResetCreditsAvailable<0)q.ResetCreditsAvailable=null;object list;if(resets.TryGetValue("credits",out list)&&list is IEnumerable&&!(list is string))foreach(object value in (IEnumerable)list){var credit=value as Dictionary<string,object>;if(credit==null||Text(credit,"status")!="available"||Text(credit,"resetType")!="codexRateLimits")continue;DateTime? expiry=Unix(credit,"expiresAt");if(expiry.HasValue&&(!q.ResetCreditExpiresAt.HasValue||expiry.Value<q.ResetCreditExpiresAt.Value))q.ResetCreditExpiresAt=expiry;}}
   bool? allowed=Bool(root,"ordinaryUsageAllowed");if(allowed==false)q.Status="已更新：服务端报告普通包含额度当前不可用";
   else if(q.Windows.Count==0)q.Status="已读取；当前未提供额度百分比，缺失值不按零计算";
   return q;
  }
  static void AddWindow(QuotaSnapshot q,string label,Dictionary<string,object> window,string role){
   if(window==null)return;double? used=Number(window,"usedPercent");if(!used.HasValue||used.Value<0)return;
   int? minutes=Int(window,"windowDurationMins");if(minutes.HasValue&&minutes.Value<=0)minutes=null;
   q.Windows.Add(new QuotaWindow{Name=label+" / "+WindowName(minutes,role),UsedPercent=used.Value,RemainingPercent=Math.Max(0,Math.Min(100,100-used.Value)),ResetAt=Unix(window,"resetsAt"),WindowMinutes=minutes});
  }
  static string WindowName(int? minutes,string role){if(!minutes.HasValue)return role;if(minutes.Value%1440==0)return (minutes.Value/1440).ToString(CultureInfo.InvariantCulture)+" 天窗口";if(minutes.Value%60==0)return (minutes.Value/60).ToString(CultureInfo.InvariantCulture)+" 小时窗口";return minutes.Value.ToString(CultureInfo.InvariantCulture)+" 分钟窗口";}
  static string Json(object o){return new JavaScriptSerializer{MaxJsonLength=1048576}.Serialize(o);}
  static Dictionary<string,object> ParseObject(string text){return new JavaScriptSerializer{MaxJsonLength=1048576}.DeserializeObject(text) as Dictionary<string,object>;}
  static Dictionary<string,object> Object(Dictionary<string,object> d,string k){object v;return d!=null&&d.TryGetValue(k,out v)?v as Dictionary<string,object>:null;}
  static string Text(Dictionary<string,object> d,string k){object v;if(d==null||!d.TryGetValue(k,out v)||v==null)return null;string s=v as string;return String.IsNullOrWhiteSpace(s)?null:s;}
  static bool? Bool(Dictionary<string,object> d,string k){object v;if(d==null||!d.TryGetValue(k,out v)||!(v is bool))return null;return (bool)v;}
  static double? Number(Dictionary<string,object> d,string k){object v;double n;if(d==null||!d.TryGetValue(k,out v)||v==null||v is bool||!Double.TryParse(Convert.ToString(v,CultureInfo.InvariantCulture),NumberStyles.Float,CultureInfo.InvariantCulture,out n)||Double.IsNaN(n)||Double.IsInfinity(n))return null;return n;}
  static int? Int(Dictionary<string,object> d,string k){double? n=Number(d,k);return n.HasValue&&n.Value>=Int32.MinValue&&n.Value<=Int32.MaxValue&&n.Value==Math.Truncate(n.Value)?(int?)n.Value:null;}
  static DateTime? Unix(Dictionary<string,object> d,string k){double? seconds=Number(d,k);if(!seconds.HasValue)return null;try{return new DateTime(1970,1,1,0,0,0,DateTimeKind.Utc).AddSeconds(seconds.Value);}catch{return null;}}
  sealed class QuotaProtocolException:Exception {public QuotaProtocolException(string message):base(message){}}
 }
}
