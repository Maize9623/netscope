using System;
using System.Text;
using System.Linq;
using System.Globalization;
using System.Collections.Generic;
using System.Web.Script.Serialization;

namespace NetScope {
 public class AiEvidence { public string Metric{get;set;} public string Value{get;set;} public string Meaning{get;set;} }
 public class AiAlternative { public string Cause{get;set;} public string Confidence{get;set;} public string Assessment{get;set;} public string Reason{get;set;} }
 public class AiReport {
  public string Summary{get;set;}
  public string Status{get;set;}
  public string PrimaryCause{get;set;}
  public string Confidence{get;set;}
  public List<AiEvidence> Evidence{get;set;}
  public List<AiAlternative> Alternatives{get;set;}
  public List<string> NextSteps{get;set;}
  public string Details{get;set;}
  public AiReport(){Evidence=new List<AiEvidence>();Alternatives=new List<AiAlternative>();NextSteps=new List<string>();}
  public static string SchemaJson {get{return @"{
  ""type"": ""object"",
  ""additionalProperties"": false,
  ""properties"": {
    ""Summary"": {""type"":""string""},
    ""Status"": {""type"":""string"",""enum"":[""normal"",""attention"",""uncertain""]},
    ""PrimaryCause"": {""type"":""string""},
    ""Confidence"": {""type"":""string"",""enum"":[""high"",""medium"",""low""]},
    ""Evidence"": {""type"":""array"",""maxItems"":6,""items"":{
      ""type"":""object"",""additionalProperties"":false,
      ""properties"":{""Metric"":{""type"":""string""},""Value"":{""type"":""string""},""Meaning"":{""type"":""string""}},
      ""required"":[""Metric"",""Value"",""Meaning""]
    }},
    ""Alternatives"": {""type"":""array"",""minItems"":3,""maxItems"":5,""items"":{
      ""type"":""object"",""additionalProperties"":false,
      ""properties"":{
        ""Cause"":{""type"":""string""},
        ""Confidence"":{""type"":""string"",""enum"":[""high"",""medium"",""low""]},
        ""Assessment"":{""type"":""string"",""enum"":[""supported"",""possible"",""not_supported"",""unknown""]},
        ""Reason"":{""type"":""string""}
      },
      ""required"":[""Cause"",""Confidence"",""Assessment"",""Reason""]
    }},
    ""NextSteps"":{""type"":""array"",""maxItems"":3,""items"":{""type"":""string""}},
    ""Details"":{""type"":""string""}
  },
  ""required"":[""Summary"",""Status"",""PrimaryCause"",""Confidence"",""Evidence"",""Alternatives"",""NextSteps"",""Details""]
}";}}
  public static AiReport Parse(string raw){
   if(String.IsNullOrWhiteSpace(raw))throw Invalid("返回内容为空，尚无结构化分析。");
   string text=raw.Trim().TrimStart('\uFEFF').Trim();
   if(text.Length>131072)throw Invalid("返回内容过长，请重新生成简洁报告。");
   if(text.Length==0||text[0]!='{')throw Invalid("需要完整的 JSON 对象；不接受 Markdown 代码块或前后说明文字。");
   new StrictJson(text).Validate();
   Dictionary<string,object> root;
   try{root=new JavaScriptSerializer{MaxJsonLength=131072,RecursionLimit=32}.DeserializeObject(text) as Dictionary<string,object>;}catch{throw Invalid("JSON 语法无效，无法安全读取报告。");}
   Fields(root,"报告","Summary","Status","PrimaryCause","Confidence","Evidence","Alternatives","NextSteps","Details");
   var result=new AiReport{Summary=RequiredText(root,"Summary",true),Status=Enum(root,"Status","normal","attention","uncertain"),PrimaryCause=RequiredText(root,"PrimaryCause",true),Confidence=Enum(root,"Confidence","high","medium","low"),Details=RequiredText(root,"Details",false)};
   var evidence=Array(root,"Evidence");if(evidence.Length>6)throw Invalid("Evidence 最多包含 6 条证据。");
   foreach(var item in evidence){var d=item as Dictionary<string,object>;Fields(d,"Evidence 项","Metric","Value","Meaning");result.Evidence.Add(new AiEvidence{Metric=RequiredText(d,"Metric",true),Value=RequiredText(d,"Value",true),Meaning=RequiredText(d,"Meaning",true)});}
   var alternatives=Array(root,"Alternatives");if(alternatives.Length<3||alternatives.Length>5)throw Invalid("Alternatives 应包含 3 至 5 个备选原因，缺乏证据时应明确标注 unknown。");
   foreach(var item in alternatives){var d=item as Dictionary<string,object>;Fields(d,"Alternatives 项","Cause","Confidence","Assessment","Reason");result.Alternatives.Add(new AiAlternative{Cause=RequiredText(d,"Cause",true),Confidence=Enum(d,"Confidence","high","medium","low"),Assessment=Enum(d,"Assessment","supported","possible","not_supported","unknown"),Reason=RequiredText(d,"Reason",true)});}
   var next=Array(root,"NextSteps");if(next.Length>3)throw Invalid("NextSteps 最多包含 3 项操作。");
   foreach(var item in next){var s=item as string;if(System.String.IsNullOrWhiteSpace(s))throw Invalid("NextSteps 每项必须是非空文字。");result.NextSteps.Add(s.Trim());}
   return result;
  }
  public string ConvertToPlainText(){
   var b=new StringBuilder();b.AppendLine(Summary??"");b.AppendLine("状态："+StatusText(Status)+"；判断信心："+ConfidenceText(Confidence));
   b.AppendLine("主要可能原因："+(PrimaryCause??"尚不能判断"));
   if(Evidence!=null&&Evidence.Count>0){b.AppendLine();b.AppendLine("测量证据");foreach(var e in Evidence)b.AppendLine("- "+e.Metric+"："+e.Value+"。"+e.Meaning);}
   if(Alternatives!=null&&Alternatives.Count>0){b.AppendLine();b.AppendLine("其他可能原因");foreach(var a in Alternatives)b.AppendLine("- "+a.Cause+"（"+AssessmentText(a.Assessment)+"，"+ConfidenceText(a.Confidence)+"）："+a.Reason);}
   if(NextSteps!=null&&NextSteps.Count>0){b.AppendLine();b.AppendLine("下一步");for(int i=0;i<NextSteps.Count;i++)b.AppendLine((i+1).ToString(CultureInfo.InvariantCulture)+". "+NextSteps[i]);}
   if(!System.String.IsNullOrWhiteSpace(Details)){b.AppendLine();b.AppendLine("详细分析");b.AppendLine(Details);}
   return b.ToString().TrimEnd();
  }
  public static string ConvertToPlainText(AiReport report){if(report==null)return "暂无 AI 分析。";return report.ConvertToPlainText();}
  static string StatusText(string s){return s=="normal"?"观测正常":s=="attention"?"需要留意":"证据不足";}
  static string ConfidenceText(string s){return s=="high"?"高":s=="medium"?"中":"低";}
  static string AssessmentText(string s){return s=="supported"?"有证据支持":s=="possible"?"可能相关":s=="not_supported"?"当前证据不支持":"信息不足";}
  static FormatException Invalid(string message){return new FormatException("AI 报告格式不符合约定："+message);}
  static void Fields(Dictionary<string,object> d,string where,params string[] fields){if(d==null)throw Invalid(where+"必须是 JSON 对象。");foreach(string field in fields)if(!d.ContainsKey(field))throw Invalid(where+"缺少字段 "+field+"。");if(d.Keys.Any(k=>!fields.Contains(k,StringComparer.Ordinal)))throw Invalid(where+"包含未知字段，不能静默忽略。");}
  static string RequiredText(Dictionary<string,object> d,string key,bool nonempty){object v;if(!d.TryGetValue(key,out v)||!(v is string))throw Invalid(key+"必须是文字，不能为 null 或数值。");string value=((string)v).Trim();if(nonempty&&System.String.IsNullOrWhiteSpace(value))throw Invalid(key+"不能为空。");return value;}
  static string Enum(Dictionary<string,object> d,string key,params string[] allowed){string value=RequiredText(d,key,true);if(!allowed.Contains(value,StringComparer.Ordinal))throw Invalid(key+"取值无效；允许："+System.String.Join("、",allowed)+"。");return value;}
  static object[] Array(Dictionary<string,object> d,string key){object value;if(!d.TryGetValue(key,out value)||!(value is object[]))throw Invalid(key+"必须是 JSON 数组，不能为 null。");return (object[])value;}
  // JavaScriptSerializer accepts a few JavaScript extensions. Validate RFC-style JSON first,
  // including duplicate-key rejection, rather than extracting or repairing model prose.
  sealed class StrictJson {
   readonly string text;int position;
   public StrictJson(string value){text=value;}
   public void Validate(){Value(0);Space();if(position!=text.Length)Fail("JSON 对象之后存在额外内容。");}
   void Space(){while(position<text.Length&&(text[position]==' '||text[position]=='\t'||text[position]=='\r'||text[position]=='\n'))position++;}
   void Value(int depth){if(depth>24)Fail("JSON 嵌套过深。");Space();if(position>=text.Length)Fail("JSON 提前结束。");char c=text[position];if(c=='{'){Object(depth+1);return;}if(c=='['){List(depth+1);return;}if(c=='"'){Quoted();return;}if(c=='t'){Literal("true");return;}if(c=='f'){Literal("false");return;}if(c=='n'){Literal("null");return;}if(c=='-'||(c>='0'&&c<='9')){Number();return;}Fail("发现非 JSON 语法；字符串和字段名必须使用双引号。");}
   void Object(int depth){position++;Space();if(Take('}'))return;var keys=new HashSet<string>(StringComparer.Ordinal);while(true){Space();if(position>=text.Length||text[position]!='"')Fail("JSON 字段名必须使用双引号。");string key=Quoted();if(!keys.Add(key))Fail("JSON 对象存在重复字段。");Space();if(!Take(':'))Fail("JSON 字段后缺少冒号。");Value(depth);Space();if(Take('}'))return;if(!Take(','))Fail("JSON 对象字段之间缺少逗号。");Space();if(position<text.Length&&text[position]=='}')Fail("JSON 不允许尾随逗号。");}}
   void List(int depth){position++;Space();if(Take(']'))return;while(true){Value(depth);Space();if(Take(']'))return;if(!Take(','))Fail("JSON 数组项之间缺少逗号。");Space();if(position<text.Length&&text[position]==']')Fail("JSON 不允许尾随逗号。");}}
   bool Take(char c){if(position<text.Length&&text[position]==c){position++;return true;}return false;}
   string Quoted(){position++;var b=new StringBuilder();while(position<text.Length){char c=text[position++];if(c=='"')return b.ToString();if(c<32)Fail("JSON 字符串含未转义控制字符。");if(c!='\\'){b.Append(c);continue;}if(position>=text.Length)Fail("JSON 转义序列未完成。");c=text[position++];switch(c){case '"':b.Append('"');break;case '\\':b.Append('\\');break;case '/':b.Append('/');break;case 'b':b.Append('\b');break;case 'f':b.Append('\f');break;case 'n':b.Append('\n');break;case 'r':b.Append('\r');break;case 't':b.Append('\t');break;case 'u':if(position+4>text.Length)Fail("Unicode 转义未完成。");string hex=text.Substring(position,4);int n;if(!Int32.TryParse(hex,NumberStyles.AllowHexSpecifier,CultureInfo.InvariantCulture,out n))Fail("Unicode 转义无效。");b.Append((char)n);position+=4;break;default:Fail("JSON 转义符无效。");break;}}Fail("JSON 字符串未闭合。");return null;}
   void Literal(string value){if(position+value.Length>text.Length||text.Substring(position,value.Length)!=value)Fail("JSON 常量无效。");position+=value.Length;}
   void Number(){Take('-');if(Take('0')){}else{if(position>=text.Length||text[position]<'1'||text[position]>'9')Fail("JSON 数值无效。");while(position<text.Length&&text[position]>='0'&&text[position]<='9')position++;}if(Take('.'))Digits();if(Take('e')||Take('E')){if(!Take('+'))Take('-');Digits();}}
   void Digits(){int begin=position;while(position<text.Length&&text[position]>='0'&&text[position]<='9')position++;if(position==begin)Fail("JSON 数值缺少数字。");}
   void Fail(string message){throw Invalid(message);}
  }
 }
}

