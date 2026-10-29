using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using NetScope;
class QuotaClientTests {
 static int count;
 static JavaScriptSerializer serializer=new JavaScriptSerializer();
 static Dictionary<string,object> Root(string json){return serializer.DeserializeObject(json) as Dictionary<string,object>;}
 static QuotaSnapshot Snapshot(Dictionary<string,object> data){var method=typeof(QuotaClient).GetMethod("ParseSnapshot",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Static);return (QuotaSnapshot)method.Invoke(null,new object[]{data});}
 static void Check(bool b,string why){if(!b)throw new Exception(why);count++;Console.WriteLine("PASS "+why);}
 static int Main(string[] args){
  var q=Snapshot(Root("{\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"usedPercent\":31,\"windowDurationMins\":10080,\"resetsAt\":1793774187},\"planType\":\"pro\"},\"other\":{\"primary\":{\"usedPercent\":101}}},\"rateLimits\":{\"primary\":{\"usedPercent\":1}}}"));
  Check(q.Windows.Count==2,"prefers all named buckets over legacy");Check(q.Windows[0].RemainingPercent==69,"remaining is 100 minus used");Check(q.Windows[1].RemainingPercent==0,"remaining clamped at zero");Check(q.Windows[0].ResetAt.Value.Kind==DateTimeKind.Utc,"reset timestamp UTC");Check(q.Plan=="pro","plan parsed");Check(q.ResetCreditsAvailable==null&&q.CreditBalance==null,"missing metadata stays null");
  q=Snapshot(Root("{\"rateLimits\":{\"primary\":{\"resetsAt\":1793774187},\"secondary\":null},\"rateLimitResetCredits\":{\"availableCount\":1,\"credits\":null}}"));Check(q.Windows.Count==0,"missing used percent not treated as zero usage");Check(q.ResetCreditsAvailable==1&&q.ResetCreditExpiresAt==null,"known reset count unknown expiry preserved");
  q=Snapshot(Root("{\"rateLimits\":{},\"rateLimitResetCredits\":{\"availableCount\":2,\"credits\":[{\"status\":\"redeemed\",\"resetType\":\"codexRateLimits\",\"expiresAt\":1},{\"status\":\"available\",\"resetType\":\"codexRateLimits\",\"expiresAt\":1793299689},{\"status\":\"available\",\"resetType\":\"codexRateLimits\",\"expiresAt\":1793299999}]}}"));Check(q.ResetCreditExpiresAt.Value==new DateTime(1970,1,1,0,0,0,DateTimeKind.Utc).AddSeconds(1793299689),"earliest available reset expiry only");
  Console.WriteLine("Synthetic tests: "+count+" passed.");
  if(args.Length>0){q=QuotaClient.ReadAsync(args[0]).GetAwaiter().GetResult();string json=serializer.Serialize(q);File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"quota-live-summary.json"),json,new UTF8Encoding(false));Console.WriteLine(json);return q.Error==null?0:2;}return 0;
 }
}

