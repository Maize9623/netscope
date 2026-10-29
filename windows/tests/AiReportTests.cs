using System;
using System.Linq;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using NetScope;
class AiReportTests {
 static int count;static JavaScriptSerializer json=new JavaScriptSerializer();
 static Dictionary<string,object> Good(){return new Dictionary<string,object>{
  {"Summary","国内响应正常，外部访问波动仍需交叉验证"},{"Status","attention"},{"PrimaryCause","共同出口或代理路径可能相关"},{"Confidence","medium"},
  {"Evidence",new object[]{new Dictionary<string,object>{{"Metric","国内对照"},{"Value","90 ms / HTTP 200"},{"Meaning","本轮收到响应"}}}},
  {"Alternatives",new object[]{Alternative("本地接入","low","not_supported","网关及国内对照已有响应，不能排除短时无线波动"),Alternative("出口或代理","medium","possible","多个外部目标同时变慢"),Alternative("目标服务","low","unknown","没有独立网络对照")}},
  {"NextSteps",new object[]{"用第二网络重复同一组目标"}},{"Details","目前只有单机单路径的采样，不能断言任何厂商全站故障。"}};}
 static Dictionary<string,object> Alternative(string cause,string confidence,string assessment,string reason){return new Dictionary<string,object>{{"Cause",cause},{"Confidence",confidence},{"Assessment",assessment},{"Reason",reason}};}
 static void Check(bool condition,string label){if(!condition)throw new Exception(label);count++;Console.WriteLine("PASS "+label);}
 static void Reject(string raw,string label){bool rejected=false;try{AiReport.Parse(raw);}catch(FormatException ex){rejected=ex.Message.Contains("AI 报告格式不符合约定");}Check(rejected,label);}
 static void SchemaObjects(object value){var d=value as Dictionary<string,object>;if(d!=null){object t;if(d.TryGetValue("type",out t)&&Convert.ToString(t)=="object"){Check(d.ContainsKey("additionalProperties")&&d["additionalProperties"] is bool&&!(bool)d["additionalProperties"],"schema object rejects extra fields");var p=d["properties"] as Dictionary<string,object>;var required=(object[])d["required"];Check(p.Keys.OrderBy(x=>x).SequenceEqual(required.Select(Convert.ToString).OrderBy(x=>x)),"schema requires every object field");}foreach(var child in d.Values)SchemaObjects(child);}else{var a=value as object[];if(a!=null)foreach(var child in a)SchemaObjects(child);}}
 static int Main(){
  string raw=json.Serialize(Good());var report=AiReport.Parse(raw);Check(report.Status=="attention"&&report.Confidence=="medium"&&report.Evidence.Count==1&&report.Alternatives.Count==3,"valid structured report parsed");
  Check(AiReport.Parse("\uFEFF  "+raw+"\r\n").Summary==report.Summary,"UTF8 BOM and surrounding whitespace accepted");
  string plain=report.ConvertToPlainText();Check(plain.Contains(report.Summary)&&plain.Contains("本地接入")&&plain.Contains("90 ms")&&plain.Contains("下一步")&&plain.Contains(report.Details),"plain text export preserves concise report and details");
  Check(!plain.Contains("概率")&&!plain.Contains("%"),"export does not invent numerical likelihoods");
  Reject("```json\n"+raw+"\n```","markdown fence rejected without extracting JSON");
  Reject("这里是报告："+raw,"prefix prose rejected");Reject(raw+"\n已完成。","trailing prose rejected");Reject("[]","array root rejected");Reject("","empty response rejected");
  var d=Good();d["Status"]="broken";Reject(json.Serialize(d),"unknown status rejected");d=Good();d["Confidence"]="95%";Reject(json.Serialize(d),"invented numeric confidence rejected");
  d=Good();d["Score"]=99;Reject(json.Serialize(d),"unknown top-level field rejected");d=Good();d.Remove("Details");Reject(json.Serialize(d),"missing required field rejected");d=Good();d["Summary"]=123;Reject(json.Serialize(d),"wrong scalar type rejected");d=Good();d["Evidence"]=null;Reject(json.Serialize(d),"null evidence array rejected");
  d=Good();((Dictionary<string,object>)((object[])d["Evidence"])[0])["Unexpected"]="x";Reject(json.Serialize(d),"unknown nested evidence field rejected");
  d=Good();((Dictionary<string,object>)((object[])d["Alternatives"])[0])["Assessment"]="certain";Reject(json.Serialize(d),"unknown cause assessment rejected");
  d=Good();d["Alternatives"]=new object[]{Alternative("单一归因","high","supported","没有对照")};Reject(json.Serialize(d),"alternative cause count enforced");
  d=Good();d["Evidence"]=Enumerable.Range(0,7).Select(i=>(object)new Dictionary<string,object>{{"Metric","M"},{"Value","1"},{"Meaning","observed"}}).ToArray();Reject(json.Serialize(d),"evidence count limited to six");
  d=Good();d["NextSteps"]=new object[]{"a","b","c","d"};Reject(json.Serialize(d),"next steps limited to three");
  Reject(raw.Substring(0,raw.Length-1)+",}","trailing comma rejected");Reject("{\"Summary\":\"first\","+raw.Substring(1),"duplicate key rejected");Reject("{\"Summ\\u0061ry\":\"first\","+raw.Substring(1),"escaped duplicate key rejected");Reject(raw.Replace("\"Summary\":","'Summary':"),"JavaScript single-quoted property rejected");Reject(raw.Replace("\"Summary\":","Summary:"),"unquoted JavaScript property rejected");
  var schema=json.DeserializeObject(AiReport.SchemaJson);Check(schema is Dictionary<string,object>,"schema is valid JSON object");SchemaObjects(schema);Check(!AiReport.SchemaJson.Contains("maxLength"),"schema omits unsupported maxLength");
  d=Good();d["Status"]="uncertain";d["Confidence"]="low";d["Evidence"]=new object[0];d["NextSteps"]=new object[0];d["Details"]="";Check(AiReport.Parse(json.Serialize(d)).Evidence.Count==0,"unknown report can preserve no measurements without fabrication");
  Console.WriteLine("RESULT "+count+" AI report checks passed. No model or network calls.");return 0;
 }
}
