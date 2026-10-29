using System;
using System.Linq;
using System.Collections.Generic;
using System.Globalization;

namespace NetScope {
 public static class ProcessInsights {
  const double BurstFloor=256.0*1024.0;
  const double UploadFloor=128.0*1024.0;
  sealed class Sample {
   public ProcessTrafficSnapshot Snapshot;
   public DateTime At;
   public bool Valid;
   public Dictionary<string,ProcessTrafficRow> Rows;
  }
  public static List<Finding> Evaluate(ProcessTrafficSnapshot current,List<ProcessTrafficSnapshot> history){
   var findings=new List<Finding>();if(current==null)return findings;
   DateTime at=Utc(current.At);
   if(current.LostEvents>0||current.IsPartial){
    findings.Add(new Finding{At=at,Key="process:incomplete",Severity="info",Title="进程流量统计不完整",Evidence="本轮间隔 "+Number(current.IntervalSeconds)+" 秒，报告丢失事件 "+current.LostEvents+" 个，部分样本标记 "+(current.IsPartial?"是":"否")+"。未知或未观察到的事件不能当作零流量。",Advice="本轮不对具体进程占比或流量异常作结论。等待完整样本；ETW 观测的是事件字节，不是全网络设备或线路带宽。",Confidence="高：采集完整性状态"});
    return findings;
   }
   var now=Build(current);if(!now.Valid)return findings;
   var previous=(history??new List<ProcessTrafficSnapshot>()).Where(s=>s!=null&&Utc(s.At)<at&&Utc(s.At)>=at.AddMinutes(-10)).GroupBy(s=>Utc(s.At)).Select(g=>g.Last()).Select(Build).OrderByDescending(s=>s.At).ToList();
   foreach(var entry in now.Rows){
    string identity=entry.Key;var row=entry.Value;double rate=Total(row);
    var baseline=previous.Where(s=>s.Valid&&s.Rows.ContainsKey(identity)).Select(s=>Total(s.Rows[identity])).ToList();
    if(baseline.Count>=10&&previous.Count>0&&Continuous(now,previous[0])&&previous[0].Rows.ContainsKey(identity)){
     double median=Median(baseline),priorRate=Total(previous[0].Rows[identity]);
     if(rate>BurstFloor&&rate>5*median&&priorRate>BurstFloor&&priorRate>5*median){
      findings.Add(new Finding{At=at,Key="process:increase:"+identity,Severity="warning",Title=SafeName(row)+" 的观测流量显著增加",Evidence="时间 "+Time(at)+"；当前下行+上行 "+KiB(rate)+" KiB/s，上一轮 "+KiB(priorRate)+" KiB/s，最近 10 分钟 "+baseline.Count+" 个同一进程有效样本中位数 "+KiB(median)+" KiB/s。连续 2 轮均超过基线 5 倍且超过 256 KiB/s；两轮相隔 "+Number((now.At-previous[0].At).TotalSeconds)+" 秒。"+MeasurementNote(row),Advice="核对这个进程当时是否在下载、更新、编译取依赖或同步。增加本身不代表恶意，也不能证明它挤满线路；需要结合本机接口、应用任务及网关数据。",Confidence=String.IsNullOrWhiteSpace(row.InstanceId)?"低：重复观测，缺少进程启动标识":"中：同进程连续观测"});
     }
    }
    if(row.UploadBps>UploadFloor){
     var chain=new List<ProcessTrafficRow>{row};Sample later=now;DateTime earliest=at;
     foreach(var sample in previous){if(chain.Count>=5)break;if(!Continuous(later,sample))break;ProcessTrafficRow older;if(!sample.Rows.TryGetValue(identity,out older)||older.UploadBps<=UploadFloor)break;chain.Add(older);earliest=sample.At;later=sample;}
     if(chain.Count>=5){
      findings.Add(new Finding{At=at,Key="process:upload:"+identity,Severity="info",Title=SafeName(row)+" 持续上传（连续 5 个样本）",Evidence="在 "+Time(earliest)+" 至 "+Time(at)+" 的 5 个连续有效样本中，每次上传均超过 128 KiB/s；该段最低 "+KiB(chain.Min(r=>r.UploadBps))+" KiB/s，最高 "+KiB(chain.Max(r=>r.UploadBps))+" KiB/s。"+MeasurementNote(row),Advice="这是上传活动记录，不是恶意或异常判定。合法的云同步、备份、会议和代码上传也会出现；可结合进程正在执行的任务查看。",Confidence=String.IsNullOrWhiteSpace(row.InstanceId)?"低：缺少进程启动标识":"中：同进程连续观测"});
     }
    }
   }
   return findings;
  }
  static Sample Build(ProcessTrafficSnapshot snapshot){
   var sample=new Sample{Snapshot=snapshot,At=Utc(snapshot.At),Valid=snapshot.At!=DateTime.MinValue&&String.Equals(snapshot.State,"Running",StringComparison.OrdinalIgnoreCase)&&Finite(snapshot.IntervalSeconds)&&snapshot.IntervalSeconds>0&&snapshot.IntervalSeconds<=10&&snapshot.LostEvents==0&&!snapshot.IsPartial,Rows=new Dictionary<string,ProcessTrafficRow>(StringComparer.Ordinal)};
   foreach(var group in (snapshot.Processes??new List<ProcessTrafficRow>()).Where(ValidRow).GroupBy(Identity,StringComparer.Ordinal)){if(group.Count()==1)sample.Rows[group.Key]=group.First();}
   return sample;
  }
  static bool Continuous(Sample later,Sample earlier){if(!later.Valid||!earlier.Valid)return false;double gap=(later.At-earlier.At).TotalSeconds;return gap>0&&gap<=10;}
  static bool ValidRow(ProcessTrafficRow row){return row!=null&&row.Pid>0&&!String.IsNullOrWhiteSpace(row.Name)&&Finite(row.DownloadBps)&&Finite(row.UploadBps)&&row.DownloadBps>=0&&row.UploadBps>=0&&Finite(row.DownloadBps+row.UploadBps);}
  static string Identity(ProcessTrafficRow row){string basic=row.Pid.ToString(CultureInfo.InvariantCulture)+"|"+row.Name.Trim().ToLowerInvariant();return String.IsNullOrWhiteSpace(row.InstanceId)?"pid-name:"+basic:"instance:"+row.InstanceId+"|"+basic;}
  static string SafeName(ProcessTrafficRow row){return row.Name.Replace("\r"," ").Replace("\n"," ")+"（PID "+row.Pid+"）";}
  static string MeasurementNote(ProcessTrafficRow row){return "数值仅为进程 ETW 事件字节；应用与 VPN/代理可能重复计量，不能相加推断线路占用率。"+(String.IsNullOrWhiteSpace(row.InstanceId)?"本次按 PID 与名称关联，短时 PID 复用仍可能混淆。":"已按进程启动标识隔离 PID 复用。");}
  static bool Finite(double value){return !Double.IsNaN(value)&&!Double.IsInfinity(value);}
  static double Total(ProcessTrafficRow row){return row.DownloadBps+row.UploadBps;}
  static double Median(List<double> values){var x=values.OrderBy(v=>v).ToArray();int n=x.Length;return n%2==0?x[n/2-1]/2.0+x[n/2]/2.0:x[n/2];}
  static string Number(double value){return Finite(value)?value.ToString("0.0",CultureInfo.InvariantCulture):"未知";}
  static string KiB(double bytes){return (bytes/1024.0).ToString("0.0",CultureInfo.InvariantCulture);}
  static string Time(DateTime value){return value.ToLocalTime().ToString("HH:mm:ss zzz",CultureInfo.InvariantCulture);}
  static DateTime Utc(DateTime value){return value.Kind==DateTimeKind.Utc?value:value.ToUniversalTime();}
 }
}

