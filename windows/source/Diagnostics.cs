using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace NetScope {
 public static class Diagnostics {
  private sealed class Observation { public DateTime At; public ProbeResult Probe; }
  public static List<Finding> Evaluate(MonitorFrame current, List<HistoryPoint> recent) {
   var findings = new List<Finding>();
   if(current == null) return findings;
   DateTime now = current.At == DateTime.MinValue ? DateTime.UtcNow : current.At;
   var probes = (current.Probes ?? new List<ProbeResult>()).Where(p=>p!=null).ToList();
   var history = Flatten(recent).Where(o=>o.At < now).OrderBy(o=>o.At).ToList();
   var adapters = current.Local == null || current.Local.Adapters == null ? new List<AdapterInfo>() : current.Local.Adapters;
   var realAdapters = adapters.Where(a=>a!=null && !IsLoopback(a)).ToList();
   bool anyControlResponse = probes.Any(HasControlResponse);
   if(realAdapters.Count > 0 && !realAdapters.Any(a=>a.IsUp)) {
    Add(findings,now,"local:link","critical","电脑目前没有连上 Wi-Fi 或网线", "本次读取的非回环网卡全部报告未连接；这是本机接口状态。", "先看看 Wi-Fi 是否连接、网线是否插好，再点击重新检查。", "高：本机观测");
   } else if(realAdapters.Count > 0 && realAdapters.Any(a=>a.IsUp && a.IsVirtual) && !realAdapters.Any(a=>a.IsUp && !a.IsVirtual)) {
    Add(findings,now,"local:virtual-only","info","检测到了 VPN 等软件的连接，还需确认电脑实际怎样上网", "虚拟网卡显示已连接，但没有识别到活动物理网卡；网卡类型识别也可能不完整。", "在“本机网络”里确认 Wi-Fi 或网线是否已连接。VPN 显示已连接，不一定说明它能正常上网。", "低：需核对接口");
   }
   if(current.Local != null && !String.IsNullOrWhiteSpace(current.Local.Gateway) && !current.GatewayMs.HasValue) {
    Add(findings,now,"gateway:no-icmp","info","路由器没回答这项检查，不一定影响上网", "本轮网关 Ping 没有返回延迟。" + (anyControlResponse ? "同时已有 HTTP 目标返回响应，因此不能据此判定网络中断。" : "这可能是禁用 ICMP、暂时丢弃探测或路径不可用。"), "先看常用网站能不能打开。如果能打开，暂时不需要因为这一项修改设置。", "高：仅确认未收到 ICMP 回复");
   } else if(current.GatewayMs.HasValue && current.GatewayMs.Value > 100) {
    Add(findings,now,"gateway:slow","warning","电脑到路由器的回应偏慢", "本轮网关 ICMP 延迟为 " + Ms(current.GatewayMs.Value) + " ms。ICMP 可能被降优先级，这不等同业务延迟。", "如果正在用 Wi-Fi，可以靠近路由器再检查；也可以接网线比较。只凭这一次还不能确定原因。", "低：单类探测");
   }
   var transportFailures = probes.Where(p=>!HasHttpResponse(p) && p.Outcome!="InvalidUrl" && p.Outcome!="Skipped" && p.Outcome!="Error").ToList();
   var domestic = probes.Where(p=>p.Group=="国内" || p.Group=="内网").ToList();
   bool domesticResponds = domestic.Any(HasControlResponse);
   var otherFailures = transportFailures.Where(p=>p.Group!="国内" && p.Group!="内网" && p.Group!="状态页").ToList();
   if(otherFailures.Count >= 2 && domesticResponds) {
    bool sustained = otherFailures.Count(p=>IsConsecutiveFailure(p,now,history)) >= 2;
    Add(findings,now,"path:shared-external",sustained?"critical":"warning","国内网站有回应，几个外部应用这次没回应", "国内或内网对照目标收到 HTTP 响应；另有 " + otherFailures.Count + " 个目标未收到 HTTP 响应。" + (sustained ? "至少两个目标在相邻两轮持续失败。" : "目前只是本轮观测。"), "先重新连接 VPN 再测；方便时换手机热点比较。在公司可以把这次报告交给 IT，目前还不能确定是谁的问题。", "中：相关性证据");
   } else if(transportFailures.Count >= 2 && probes.Count > 0 && !anyControlResponse) {
    bool sustained = transportFailures.Count(p=>IsConsecutiveFailure(p,now,history)) >= 2;
    Add(findings,now,"path:all-failed",sustained?"critical":"warning","这次几个网站都没回应，还不知道卡在哪里", "共 " + transportFailures.Count + " 个目标传输失败，尚无可用于比较的 HTTP 对照；本机接入、代理、DNS 或共同出口均可能相关。"+(probes.Any(p=>p.StatusCode==407)?"其中代理认证响应 HTTP 407 只证明代理要求认证，目标服务仍未验证。":""), "先确认 Wi-Fi 或网线已连接，再打开常用国内网站；仍打不开时，可换手机热点比较。", "中：故障范围仍未定位");
   } else if(transportFailures.Count == 1 && probes.Any(HasControlResponse)) {
    var failed = transportFailures[0];
    bool sustained=IsConsecutiveFailure(failed,now,history);
    Add(findings,now,"path:isolated:"+Key(failed),sustained?"warning":"info",SafeName(failed)+" 这次没回应，其他网站有回应", "只有该目标未收到 HTTP 响应；同轮其他目标有 HTTP 响应。"+(sustained?"该现象连续出现两轮。":"单次结果仍可能是短时波动。"), "先打开这个应用试一下。若仍然打不开，隔一会儿重测，或换一个网络比较。", "低：目标路径待交叉验证");
   }
   foreach(var p in probes) {
    string key=Key(p), name=SafeName(p);
    if(p.Outcome=="Error") { Add(findings,now,"collector:error:"+key,"info",name+"：这次没检查成功","采集器发生内部或未分类异常，无法得到本轮 HTTP 结论；未计入可达率与传输失败率分母。","保留采集错误并等待下一轮。先核查检测程序、系统环境与代理配置，不要据此认定目标服务故障。","高：仅确认采集未完成"); continue; }
    if(p.Outcome=="Skipped") { Add(findings,now,"collector:skipped:"+key,"info",name+"：这次还没测到","采集器繁忙，未执行本轮 HTTP 探测；这不是目标服务返回的故障，未计入可达率和失败率分母。","稍后再测。只是程序这次没来得及检查，不能说应用坏了。","高：采集器状态"); continue; }
    if(p.Outcome=="InvalidUrl") {
     Add(findings,now,"config:"+key,"warning",name+" 的检测设置需要修改","检测器未发出有效探测；这不是网络故障。","在自定义页面填写完整的 http:// 或 https:// 地址。","高：配置检查"); continue;
    }
    if(!HasHttpResponse(p)) {
     bool sustained=IsConsecutiveFailure(p,now,history);
     string reason=FailureLabel(p);
     Add(findings,now,"transport:"+key,sustained?"warning":"info",name+"："+reason,
      "本轮没有收到 HTTP 响应。"+(sustained?"相邻两轮出现相同层级的传输失败。":"尚无相邻两轮持续失败证据。")+"本地 DNS："+(p.DnsMs.HasValue?Ms(p.DnsMs.Value)+" ms":"无测得结果")+"；直接 TCP："+(p.TcpMs.HasValue?Ms(p.TcpMs.Value)+" ms":"无测得结果")+"。",
      "先试着打开这个应用，再过一会儿重新检查；一次没回应不代表整个网络断了。",sustained?"中：重复观测":"低：单次或间隔采样");
     continue;
    }
    int code=p.StatusCode.GetValueOrDefault();
    if(code==407) { Add(findings,now,"proxy:auth:"+key,"warning",name+"：上网通道要求先登录","收到 HTTP 407，表示代理要求认证。这是代理层响应，不能作为国内或外网目标正常的对照，也不等同于目标厂商故障。","先完成公司网络或 VPN 的登录，再点重新检查。","高：代理认证响应事实；目标状态未知"); continue; }
    if(code==401 || code==403 || code==404 || code==405) {
     string interpretation=code==401?"需要认证":code==403?"访问被拒绝":code==404?"该接口路径不存在":"该接口不支持探测方法";
     Add(findings,now,"http:restriction:"+key,"info",name+"：有回应，还没验证能否正常使用",interpretation+"。该结果说明请求获得 HTTP 响应，不能当作断网，也未验证模型推理或账号可用性。","打开这个应用试试。如果不能正常使用，请保留应用里的错误提示；本项只检查有没有回应。","高：HTTP 响应事实");
    } else if(code==429) {
     Add(findings,now,"http:429:"+key,"warning",name+" 要求少发一些请求","收到 HTTP 429；限制可能来自目标服务、CDN 或代理，未证明是账号额度耗尽。","等一会儿再试，暂时不要连续点击检测。也可以在设置里调低检查频率。","高：响应事实；来源待确认");
    } else if(code>=500 && code<=599) {
     Add(findings,now,"http:5xx:"+key,"warning",name+" 发回了错误提示","网络收到服务端、CDN 或代理的异常响应。单机单路径无法确定是哪一层生成该响应。","稍后重测，或换手机热点打开同一个应用。现在还不能确定是应用服务还是上网通道的问题。","中：异常响应，责任层未定位");
    } else if(code>=300 && code<=399) {
     Add(findings,now,"http:redirect:"+key,"info",name+" 有回应，要求打开另一个页面","收到 HTTP "+code+"；检测器没有跟随跳转，尚未验证最终页面。","如果应用能正常使用，暂时不需要处理；想进一步检查，可以在设置里选用实际打开的页面。","高：HTTP 响应事实");
    } else if(code>=400) {
     Add(findings,now,"http:other:"+key,"info",name+" 发回了错误提示","已收到 HTTP 响应；这是应用层状态，不等同网络传输中断。","打开应用看看能否正常使用。这项检查没有登录账号，也没有尝试发送聊天内容。","高：HTTP 响应事实");
    }
    if(!p.DnsMs.HasValue || !p.TcpMs.HasValue) {
     Add(findings,now,"path:proxy-difference:"+key,"info",name+" 已有回应，但两种检查方式的结果不同", "HTTP 收到响应，但"+(!p.DnsMs.HasValue?"本地 DNS 没有测得结果":"")+(!p.DnsMs.HasValue&&!p.TcpMs.HasValue?"且":"")+(!p.TcpMs.HasValue?"直接 TCP 没有测得结果":"")+"。代理可能代为解析或走另一条路线。", "先以实际应用能否使用为准，暂时不要修改网络设置。需要时可以把技术详情交给 IT。", "中：路径差异");
    }
    if(p.HttpMs.HasValue && p.HttpMs.Value>1500) {
     var baseline=history.Where(o=>Key(o.Probe)==key && o.At >= now.AddMinutes(-30) && HasControlResponse(o.Probe) && Valid(o.Probe.HttpMs)).Select(o=>o.Probe.HttpMs.Value).ToList();
     if(baseline.Count>=5) {
      double median=Percentile(baseline,0.5);
      if(p.HttpMs.Value>Math.Max(1,median)*3) Add(findings,now,"latency:"+key,"warning",name+" 这次比平常回应慢很多", "本轮 "+Ms(p.HttpMs.Value)+" ms；过去 30 分钟 "+baseline.Count+" 个有效样本的中位数为 "+Ms(median)+" ms，已超过 3 倍且超过 1500 ms。", "看看其他应用是否也变慢，再过一会儿检查。仅凭这一项还分不清是 VPN 慢还是应用本身慢。", "中：相对历史异常");
     }
    }
   }
   return findings;
  }
  public static string Summarize(List<HistoryPoint> history) {
   var points=(history??new List<HistoryPoint>()).Where(p=>p!=null).OrderBy(p=>p.At).ToList();
   var sb=new StringBuilder();
   sb.AppendLine("网络观测摘要（本机、当前访问路径）");
   if(points.Count==0) {sb.AppendLine("暂无历史采样。开始监测后才会产生真实曲线和统计；空白时段不代表网络故障。");return sb.ToString();}
   sb.AppendLine("记录时段："+Time(points.First().At)+" 至 "+Time(points.Last().At));
   sb.AppendLine("本地记录："+points.Count+" 个时间点；仅统计实际保存的样本，暂停、休眠和未运行时段不补为失败。");
   double peakDown=points.Select(p=>Math.Max(Finite(p.DownloadBps)&&p.DownloadBps>=0?p.DownloadBps:0,Valid(p.DownloadPeakBps)?p.DownloadPeakBps.Value:0)).DefaultIfEmpty(0).Max();
   double peakUp=points.Select(p=>Math.Max(Finite(p.UploadBps)&&p.UploadBps>=0?p.UploadBps:0,Valid(p.UploadPeakBps)?p.UploadPeakBps.Value:0)).DefaultIfEmpty(0).Max();
   sb.AppendLine("记录到的本机峰值：下载 "+Rate(peakDown)+"，上传 "+Rate(peakUp)+"。这是所选网卡的实际流量，不是宽带总容量或全网设备流量。");
   var observations=Flatten(points);
   if(observations.Count==0) sb.AppendLine("尚无端点检测结果；本地网卡记录不等同外网服务可用性。");
   foreach(var group in observations.GroupBy(o=>Key(o.Probe)).OrderBy(g=>SafeName(g.Last().Probe),StringComparer.OrdinalIgnoreCase)) {
    var values=group.ToList();int total=values.Count, http=values.Count(o=>HasHttpResponse(o.Probe));
    int timeout=values.Count(o=>o.Probe.Outcome=="Timeout");
    int invalid=values.Count(o=>o.Probe.Outcome=="InvalidUrl");
    int skipped=values.Count(o=>o.Probe.Outcome=="Skipped");
    int collectorErrors=values.Count(o=>o.Probe.Outcome=="Error");
    int validDenominator=total-invalid-skipped-collectorErrors;
    int failed=values.Count(o=>!HasHttpResponse(o.Probe)&&o.Probe.Outcome!="InvalidUrl"&&o.Probe.Outcome!="Skipped"&&o.Probe.Outcome!="Error");
    var ms=values.Where(o=>HasHttpResponse(o.Probe)&&Valid(o.Probe.HttpMs)).Select(o=>o.Probe.HttpMs.Value).ToList();
    sb.AppendLine();sb.AppendLine(SafeName(values.Last().Probe)+"："+validDenominator+" 次有效配置探测"+(invalid>0?"（另有 "+invalid+" 次无效地址）":"")+(skipped>0?"（另有 "+skipped+" 次采集器漏测，未计入分母）":"")+(collectorErrors>0?"（另有 "+collectorErrors+" 次采集器异常，未计入分母）":""));
    sb.AppendLine("  HTTP 响应率 "+Percent(http,validDenominator)+"（"+http+"/"+validDenominator+"）；采样传输失败率 "+Percent(failed,validDenominator)+"；超时占比 "+Percent(timeout,validDenominator)+"。");
    sb.AppendLine("  HTTP 响应耗时 P50 / P95："+(ms.Count>0?Ms(Percentile(ms,0.5))+" / "+Ms(Percentile(ms,0.95))+" ms（"+ms.Count+" 个响应样本）":"暂无有效响应耗时"));
    var codes=values.Where(o=>o.Probe.StatusCode.HasValue).GroupBy(o=>o.Probe.StatusCode.Value).OrderBy(g=>g.Key).Select(g=>g.Key+" × "+g.Count());
    string codeText=String.Join("，",codes.ToArray());if(codeText.Length>0) sb.AppendLine("  HTTP 响应码："+codeText+"。");
    int proxyAuthCount=values.Count(o=>o.Probe.StatusCode==407);if(proxyAuthCount>0)sb.AppendLine("  其中 "+proxyAuthCount+" 次 HTTP 407 仅确认代理要求认证，尚未验证目标端点；这些是已收到的 HTTP 响应，不计为传输失败。");
   }
   sb.AppendLine();
   sb.AppendLine("口径：HTTP 401/403/404/405/429/5xx 都说明收到 HTTP 响应，但不代表模型推理、账号或业务功能正常；HTTP 200 也只验证被测端点响应。HTTP 407 只确认代理层响应，尚未验证目标端点。采样失败率与超时占比不是网络丢包率。");
   sb.AppendLine("限制：直接 DNS/TCP、系统代理 HTTP 和网关 ICMP 可能观察不同路径。单机单路径的相关性不能证明厂商全站故障，也不能分离公司出口、VPN 节点和服务端的全部贡献。设备带宽需网关数据，连接数不能替代带宽。");
   return sb.ToString();
  }
  private static void Add(List<Finding> list,DateTime at,string key,string severity,string title,string evidence,string advice,string confidence){list.Add(new Finding{At=at,Key=key,Severity=severity,Title=title,Evidence="本轮 1 组采样。"+evidence,Advice=advice,Confidence=confidence});}
  private static bool HasHttpResponse(ProbeResult p){return p!=null && (p.Reachable || (p.StatusCode.HasValue && p.StatusCode.Value>=100 && p.StatusCode.Value<=599));}
  private static bool HasControlResponse(ProbeResult p){return HasHttpResponse(p)&&p.StatusCode!=407&&p.Outcome!="ProxyAuthRequired";}
  private static bool Valid(double? v){return v.HasValue&&v.Value>=0&&Finite(v.Value);}
  private static bool Finite(double v){return !Double.IsNaN(v)&&!Double.IsInfinity(v);}
  private static bool IsLoopback(AdapterInfo a){return String.Equals(a.Type,"Loopback",StringComparison.OrdinalIgnoreCase)||String.Equals(a.Type,"SoftwareLoopback",StringComparison.OrdinalIgnoreCase);}
  private static string Key(ProbeResult p){return (p.TargetId??p.Name??"unknown")+"|"+(p.Url??"")+"|"+(p.PathId??"");}
  private static string SafeName(ProbeResult p){return (p.Name??p.TargetId??"未命名目标").Replace("\r"," ").Replace("\n"," ");}
  private static string Ms(double value){return value.ToString("0.0",CultureInfo.InvariantCulture);}
  private static string Percent(int numerator,int denominator){return denominator<=0?"不可计算":(100.0*numerator/denominator).ToString("0.0",CultureInfo.InvariantCulture)+"%";}
  private static string Time(DateTime value){return value.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz",CultureInfo.InvariantCulture);}
  private static string Rate(double bytes){return (bytes*8/1000000.0).ToString("0.00",CultureInfo.InvariantCulture)+" Mbps";}
  private static string FailureLabel(ProbeResult p){switch(p.Outcome){case "Timeout":return "这次等了太久，没有回应";case "TlsError":return "安全连接没有建立成功";case "ProxyError":return "通过当前上网通道没有连接成功";case "DnsError":return "没有找到网站的连接位置";case "ConnectError":return "连接未完成";default:return "这次没有等到回应";}}
  private static List<Observation> Flatten(List<HistoryPoint> points){
   var list=new List<Observation>();if(points==null)return list;
   foreach(var point in points.Where(p=>p!=null)) foreach(var probe in (point.Probes??new List<ProbeResult>()).Where(p=>p!=null)) list.Add(new Observation{At=probe.At==DateTime.MinValue?point.At:probe.At,Probe=probe});
   return list.GroupBy(o=>Key(o.Probe)+"|"+o.At.Ticks.ToString(CultureInfo.InvariantCulture)).Select(g=>g.Last()).OrderBy(o=>o.At).ToList();
  }
  private static bool IsConsecutiveFailure(ProbeResult current,DateTime now,List<Observation> all){
   var earlier=all.Where(o=>Key(o.Probe)==Key(current)&&o.At<now).OrderByDescending(o=>o.At).Take(11).ToList();
   if(earlier.Count==0 || HasHttpResponse(earlier[0].Probe) || earlier[0].Probe.Outcome=="InvalidUrl" || earlier[0].Probe.Outcome=="Skipped" || earlier[0].Probe.Outcome=="Error")return false;
   var intervals=new List<double>();for(int i=0;i+1<earlier.Count;i++){double gap=(earlier[i].At-earlier[i+1].At).TotalSeconds;if(gap>=1&&gap<=300)intervals.Add(gap);}
   double cadence=intervals.Count>0?Percentile(intervals,0.5):30;
   double maxGap=Math.Max(60,Math.Min(180,cadence*2.5));
   return (now-earlier[0].At).TotalSeconds<=maxGap;
  }
  private static double Percentile(List<double> values,double p){var sorted=values.OrderBy(v=>v).ToArray();if(sorted.Length==0)return 0;if(sorted.Length==1)return sorted[0];double rank=(sorted.Length-1)*p;int lower=(int)Math.Floor(rank),upper=(int)Math.Ceiling(rank);return sorted[lower]+(sorted[upper]-sorted[lower])*(rank-lower);}
 }
}






