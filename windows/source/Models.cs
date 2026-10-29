using System;
using System.Collections.Generic;
namespace NetScope {
 public class ProbeTarget { public string Id{get;set;} public string Name{get;set;} public string Group{get;set;} public string Url{get;set;} public bool Enabled{get;set;} public ProbeTarget(){Enabled=true;} }
 public class AppSettings { public bool AiAutoEnabled{get;set;} public int AiIntervalMinutes{get;set;} public bool AiOnAnomaly{get;set;} public int MaxAiCallsPerDay{get;set;} public int IntervalSeconds{get;set;} public int TimeoutSeconds{get;set;} public int RetentionDays{get;set;} public bool NotificationsEnabled{get;set;} public bool AutoMonitor{get;set;} public string TrafficAdapterId{get;set;} public string CodexPath{get;set;} public List<ProbeTarget> Targets{get;set;} public AppSettings(){AiAutoEnabled=true;AiIntervalMinutes=30;AiOnAnomaly=true;MaxAiCallsPerDay=60;IntervalSeconds=30;TimeoutSeconds=8;RetentionDays=30;NotificationsEnabled=false;AutoMonitor=true;TrafficAdapterId="auto";Targets=new List<ProbeTarget>();} }
 public class AdapterInfo { public string Id{get;set;} public string Name{get;set;} public string Description{get;set;} public string Type{get;set;} public string Status{get;set;} public bool IsVirtual{get;set;} public bool IsUp{get;set;} public string Mac{get;set;} public string Addresses{get;set;} public string Gateways{get;set;} public string DnsServers{get;set;} public double LinkMbps{get;set;} public long ReceivedBytes{get;set;} public long SentBytes{get;set;} public double DownloadBps{get;set;} public double UploadBps{get;set;} }
 public class LocalSample { public bool TrafficRateReady{get;set;} public DateTime At{get;set;} public List<AdapterInfo> Adapters{get;set;} public double DownloadBps{get;set;} public double UploadBps{get;set;} public string TrafficAdapterId{get;set;} public string TrafficAdapterName{get;set;} public string Gateway{get;set;} public string ProxySummary{get;set;} public LocalSample(){At=DateTime.UtcNow;Adapters=new List<AdapterInfo>();} }
 public class ProbeResult { public string PathId{get;set;} public DateTime At{get;set;} public string TargetId{get;set;} public string Name{get;set;} public string Group{get;set;} public string Url{get;set;} public double? DnsMs{get;set;} public double? TcpMs{get;set;} public double? HttpMs{get;set;} public int? StatusCode{get;set;} public bool Reachable{get;set;} public string Outcome{get;set;} public string Error{get;set;} public string Route{get;set;} public string Address{get;set;} }
 public class Finding { public DateTime At{get;set;} public string Key{get;set;} public string Severity{get;set;} public string Title{get;set;} public string Evidence{get;set;} public string Advice{get;set;} public string Confidence{get;set;} }
 public class MonitorFrame { public DateTime At{get;set;} public LocalSample Local{get;set;} public List<ProbeResult> Probes{get;set;} public double? GatewayMs{get;set;} public List<Finding> Findings{get;set;} public MonitorFrame(){At=DateTime.UtcNow;Probes=new List<ProbeResult>();Findings=new List<Finding>();} }
 public class DeviceInfo { public string InferredType{get;set;} public string InferenceReason{get;set;} public string InferenceConfidence{get;set;} public string NameSource{get;set;} public string ReportedName{get;set;} public string ReportedNameSource{get;set;} public string ReportedHint{get;set;} public string Ip{get;set;} public string Mac{get;set;} public string Name{get;set;} public string Hint{get;set;} public string State{get;set;} public string Source{get;set;} public double? DownloadBps{get;set;} public double? UploadBps{get;set;} public DateTime? ObservedAt{get;set;} }
 public class ConnectionInfo { public int Pid{get;set;} public string ProcessName{get;set;} public string LocalEndpoint{get;set;} public string RemoteEndpoint{get;set;} public string State{get;set;} }
 public class SpeedTestResult { public DateTime At{get;set;} public long Bytes{get;set;} public double Seconds{get;set;} public double Mbps{get;set;} public string Error{get;set;} public string Route{get;set;} }
 public class HistoryPoint { public string TrafficAdapterId{get;set;} public string NetworkProfileId{get;set;} public double? DownloadPeakBps{get;set;} public double? UploadPeakBps{get;set;} public int SampleCount{get;set;} public double SpanSeconds{get;set;} public DateTime At{get;set;} public double DownloadBps{get;set;} public double UploadBps{get;set;} public double? GatewayMs{get;set;} public List<ProbeResult> Probes{get;set;} public HistoryPoint(){Probes=new List<ProbeResult>();} }
 public static class Defaults {
 public static AppSettings Create(){var s=new AppSettings();
 Add(s,"baidu","百度","国内","https://www.baidu.com/",true);
 Add(s,"aliyun","阿里云","国内","https://www.aliyun.com/",false);
 Add(s,"tencent","腾讯云","国内","https://cloud.tencent.com/",false);
 Add(s,"cloudflare","Cloudflare","国际","https://www.cloudflare.com/cdn-cgi/trace",true);
 Add(s,"github","GitHub","开发","https://github.com/",true);
 Add(s,"openai","OpenAI API","AI","https://api.openai.com/v1/models",true);
 Add(s,"anthropic","Claude API","AI","https://api.anthropic.com/",true);
 Add(s,"deepseek","DeepSeek API","AI","https://api.deepseek.com/models",true);
 Add(s,"xai","Grok / xAI API","AI","https://api.x.ai/v1/models",true);
 Add(s,"gemini","Gemini API","AI","https://generativelanguage.googleapis.com/",false);
 Add(s,"cursor","Cursor 网站","开发","https://www.cursor.com/",false);
 Add(s,"copilot","Copilot 网站","开发","https://copilot.microsoft.com/",false);
 Add(s,"qwen","通义千问 API","AI","https://dashscope.aliyuncs.com/",false);
 Add(s,"doubao","豆包网站","AI","https://www.doubao.com/",false);
 Add(s,"npm","npm registry","开发","https://registry.npmjs.org/",false);
 Add(s,"pypi","PyPI","开发","https://pypi.org/",false);
 Add(s,"huggingface","Hugging Face","开发","https://huggingface.co/",false);
 Add(s,"openai-status","OpenAI 状态页","状态页","https://status.openai.com/api/v2/status.json",false);
 Add(s,"claude-status","Claude 状态页","状态页","https://status.claude.com/api/v2/status.json",false);
 return s; }
 static void Add(AppSettings s,string id,string name,string group,string url,bool enabled){s.Targets.Add(new ProbeTarget{Id=id,Name=name,Group=group,Url=url,Enabled=enabled});}
 }
}






