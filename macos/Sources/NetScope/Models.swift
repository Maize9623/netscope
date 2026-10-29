import Foundation
struct ProbeTarget: Codable, Identifiable, Hashable { var id=UUID().uuidString; var name=""; var group=""; var url=""; var enabled=true }
struct AppSettings: Codable {
 var intervalSeconds=30; var timeoutSeconds=8; var retentionDays=30
 var autoMonitor=true; var notificationsEnabled=false; var trafficAdapterID="auto"; var targets=Defaults.targets
 var aiAutoEnabled=true; var aiOnAnomaly=true; var aiIntervalMinutes=30; var maxAiCallsPerDay=60; var codexPath=""
 init() {}
 private enum CodingKeys:String,CodingKey { case intervalSeconds,timeoutSeconds,retentionDays,autoMonitor,notificationsEnabled,trafficAdapterID,targets,aiAutoEnabled,aiOnAnomaly,aiIntervalMinutes,maxAiCallsPerDay,codexPath }
 init(from decoder:Decoder)throws {
  self.init();let c=try decoder.container(keyedBy:CodingKeys.self)
  intervalSeconds=min(3600,max(15,try c.decodeIfPresent(Int.self,forKey:.intervalSeconds) ?? 30))
  timeoutSeconds=min(20,max(3,try c.decodeIfPresent(Int.self,forKey:.timeoutSeconds) ?? 8))
  retentionDays=min(90,max(1,try c.decodeIfPresent(Int.self,forKey:.retentionDays) ?? 30))
  autoMonitor=try c.decodeIfPresent(Bool.self,forKey:.autoMonitor) ?? true
  notificationsEnabled=try c.decodeIfPresent(Bool.self,forKey:.notificationsEnabled) ?? false
  trafficAdapterID=try c.decodeIfPresent(String.self,forKey:.trafficAdapterID) ?? "auto"
  targets=try c.decodeIfPresent([ProbeTarget].self,forKey:.targets) ?? Defaults.targets
  aiAutoEnabled=try c.decodeIfPresent(Bool.self,forKey:.aiAutoEnabled) ?? true
  aiOnAnomaly=try c.decodeIfPresent(Bool.self,forKey:.aiOnAnomaly) ?? true
  aiIntervalMinutes=min(1440,max(5,try c.decodeIfPresent(Int.self,forKey:.aiIntervalMinutes) ?? 30))
  maxAiCallsPerDay=min(200,max(0,try c.decodeIfPresent(Int.self,forKey:.maxAiCallsPerDay) ?? 60))
  codexPath=try c.decodeIfPresent(String.self,forKey:.codexPath) ?? ""
 }
}
struct AdapterInfo:Codable,Identifiable {
 var id="";var name="";var description="";var type="";var status="";var isVirtual=false;var isUp=false;var mac=""
 var addresses:[String]=[];var gateways:[String]=[];var dnsServers:[String]=[];var linkMbps:Double?
 var receivedBytes:UInt64=0;var sentBytes:UInt64=0;var downloadBps:Double?;var uploadBps:Double?
}
struct LocalSample:Codable {
 var at=Date();var adapters:[AdapterInfo]=[];var downloadBps:Double?;var uploadBps:Double?;var trafficRateReady=false
 var trafficAdapterID="";var trafficAdapterName="等待本机接口采样";var gateway:String?;var proxySummary="尚未读取系统代理配置"
}
enum ProbeOutcome:String,Codable,CaseIterable {
 case ok,redirect,authRequired,forbidden,notFound,methodNotAllowed,rateLimited,proxyAuthRequired,serverError,httpError
 case timeout,dnsError,tlsError,proxyError,connectError,invalidURL,skipped,error
 var isHTTPResponse:Bool { switch self { case .ok,.redirect,.authRequired,.forbidden,.notFound,.methodNotAllowed,.rateLimited,.proxyAuthRequired,.serverError,.httpError:return true;default:return false } }
 var isPositiveControl:Bool { isHTTPResponse && self != .proxyAuthRequired && self != .serverError }
 var isMissing:Bool { self == .skipped || self == .error || self == .invalidURL }
 var isTransportFailure:Bool { switch self { case .timeout,.dnsError,.tlsError,.proxyError,.connectError:return true;default:return false } }
}
struct ProbeResult:Codable,Identifiable {
 var id:String { targetID };var at=Date();var targetID="";var name="";var group="";var url=""
 var dnsMs:Double?;var tcpMs:Double?;var tlsMs:Double?;var httpMs:Double?;var statusCode:Int?;var reachable=false
 var outcome:ProbeOutcome = .error;var error="";var route="";var pathID="";var address:String?
 var isProxyConnection:Bool?;var isReusedConnection:Bool?;var networkProtocol:String?
}
enum FindingSeverity:String,Codable { case info,warning,critical }
struct Finding:Codable,Identifiable { var id=UUID().uuidString;var at=Date();var severity:FindingSeverity = .info;var title="";var evidence="";var advice="";var confidence="" }
struct MonitorFrame:Codable,Identifiable { var id:Date { at };var at=Date();var local=LocalSample();var probes:[ProbeResult]=[];var gatewayMs:Double?;var findings:[Finding]=[] }
struct DeviceInfo:Codable,Identifiable { var id:String { ip+"|"+mac+"|"+source };var ip="";var mac="";var name="未知";var hint="设备类型未知";var state="未知";var source="";var downloadBps:Double?;var uploadBps:Double?;var observedAt:Date? }
enum Defaults {
 static var targets:[ProbeTarget] {
  let rows:[(String,String,String,String,Bool)] = [
   ("baidu","百度","国内","https://www.baidu.com/",true),
   ("aliyun","阿里云","国内","https://www.aliyun.com/",false),
   ("tencent","腾讯云","国内","https://cloud.tencent.com/",false),
   ("cloudflare","Cloudflare","国际","https://www.cloudflare.com/cdn-cgi/trace",true),
   ("github","GitHub","开发","https://github.com/",true),
   ("openai","OpenAI API","AI","https://api.openai.com/v1/models",true),
   ("anthropic","Claude API","AI","https://api.anthropic.com/",true),
   ("deepseek","DeepSeek API","AI","https://api.deepseek.com/models",true),
   ("xai","Grok / xAI API","AI","https://api.x.ai/v1/models",true),
   ("gemini","Gemini API","AI","https://generativelanguage.googleapis.com/",false),
   ("cursor","Cursor 网站","开发","https://www.cursor.com/",false),
   ("copilot","Copilot 网站","开发","https://copilot.microsoft.com/",false),
   ("qwen","通义千问 API","AI","https://dashscope.aliyuncs.com/",false),
   ("doubao","豆包网站","AI","https://www.doubao.com/",false),
   ("npm","npm registry","开发","https://registry.npmjs.org/",false),
   ("pypi","PyPI","开发","https://pypi.org/",false),
   ("huggingface","Hugging Face","开发","https://huggingface.co/",false),
   ("openai-status","OpenAI 状态页","状态页","https://status.openai.com/api/v2/status.json",false),
   ("claude-status","Claude 状态页","状态页","https://status.claude.com/api/v2/status.json",false)
  ]
  return rows.map { ProbeTarget(id:$0.0,name:$0.1,group:$0.2,url:$0.3,enabled:$0.4) }
 }
}
enum BackendMath {
 static func counterRates(previousReceived:UInt64?,previousSent:UInt64?,received:UInt64,sent:UInt64,elapsed:Double)->(download:Double?,upload:Double?) {
  guard elapsed.isFinite,elapsed>=0.05,elapsed<=10,let oldReceived=previousReceived,let oldSent=previousSent,received>=oldReceived,sent>=oldSent else { return (nil,nil) }
  return (Double(received-oldReceived)/elapsed,Double(sent-oldSent)/elapsed)
 }
}
enum BackendValidation {
 static func targetURL(_ value:String)->URL? {
  var text=value.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !text.isEmpty,!text.contains(where:{$0.isWhitespace || $0.isNewline}) else { return nil }
  if !text.contains("://") { text="https://"+text }
  guard let p=URLComponents(string:text),let scheme=p.scheme?.lowercased(),scheme=="http" || scheme=="https",let host=p.host,!host.isEmpty,p.user==nil,p.password==nil,let url=p.url else { return nil }
  return url
 }
 static func normalizedMAC(_ value:String)->String? {
  let text=value.lowercased().trimmingCharacters(in:.whitespacesAndNewlines)
  let parts=text.split(omittingEmptySubsequences:false,whereSeparator:{$0 == ":" || $0 == "-"})
  if parts.count == 6 {
   guard parts.allSatisfy({(1...2).contains($0.count) && $0.allSatisfy({$0.isHexDigit && $0.isASCII})}) else { return nil }
   return parts.map { $0.count == 1 ? "0"+String($0) : String($0) }.joined(separator:":")
  }
  guard text.count==12,text.allSatisfy({$0.isHexDigit && $0.isASCII}) else { return nil }
  let chars=Array(text);return stride(from:0,to:12,by:2).map{String(chars[$0...($0+1)])}.joined(separator:":")
 }
}
enum BackendCSV {
 static func escape(_ value:String)->String {
  let clean=value.trimmingCharacters(in:.whitespacesAndNewlines)
  let guarded=clean.first.map{"=+-@".contains($0)} == true ? "'"+value:value
  return "\""+guarded.replacingOccurrences(of:"\"",with:"\"\"")+"\""
 }
}


