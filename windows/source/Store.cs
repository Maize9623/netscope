using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Collections.Generic;
using System.Web.Script.Serialization;
namespace NetScope {
 public sealed class Store {
  public string DirectoryPath {get;private set;} private object sync=new object();
  public Store(string path){DirectoryPath=Path.GetFullPath(path);Directory.CreateDirectory(DirectoryPath);}
  public static string Json(object value){return new JavaScriptSerializer{MaxJsonLength=16777216}.Serialize(value);}
  public static T Parse<T>(string text){return new JavaScriptSerializer{MaxJsonLength=16777216}.Deserialize<T>(text);}
  public AppSettings LoadSettings(){string p=Path.Combine(DirectoryPath,"settings.json");if(!File.Exists(p))return Defaults.Create();try{return Parse<AppSettings>(File.ReadAllText(p,Encoding.UTF8))??Defaults.Create();}catch{File.Copy(p,p+".invalid-"+DateTime.UtcNow.ToString("yyyyMMddHHmmss"),true);return Defaults.Create();}}
  public void SaveSettings(AppSettings s){lock(sync){string p=Path.Combine(DirectoryPath,"settings.json"),t=p+".tmp";File.WriteAllText(t,Json(s),new UTF8Encoding(false));if(File.Exists(p))File.Replace(t,p,null);else File.Move(t,p);}}
  public void Append(string prefix,object value){lock(sync){string p=Path.Combine(DirectoryPath,prefix+"-"+DateTime.UtcNow.ToString("yyyy-MM-dd")+".jsonl");byte[] line=new UTF8Encoding(false).GetBytes(Json(value)+Environment.NewLine);using(var file=new FileStream(p,FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.Read)){if(file.Length>0){file.Seek(-1,SeekOrigin.End);int tail=file.ReadByte();file.Seek(0,SeekOrigin.End);if(tail!=10){byte[] separator=Encoding.UTF8.GetBytes(Environment.NewLine);file.Write(separator,0,separator.Length);}}file.Write(line,0,line.Length);}}}
  public List<HistoryPoint> LoadHistory(int days){var all=new List<HistoryPoint>();DateTime from=DateTime.UtcNow.AddDays(-days);foreach(var p in System.IO.Directory.GetFiles(DirectoryPath,"history-*.jsonl").OrderBy(x=>x)){DateTime day;if(!DateTime.TryParse(Path.GetFileNameWithoutExtension(p).Substring(8),out day)||day.Date<from.Date)continue;foreach(var line in File.ReadLines(p)){try{if(line.Length>1048576)continue;var h=Parse<HistoryPoint>(line);h.At=h.At.ToUniversalTime();if(h.At>=from){h.Probes=h.Probes??new List<ProbeResult>();all.Add(h);}}catch{}}}return all.OrderBy(h=>h.At).ToList();}
  public List<Finding> LoadEvents(int days){var all=new List<Finding>();DateTime from=DateTime.UtcNow.AddDays(-days);foreach(var p in System.IO.Directory.GetFiles(DirectoryPath,"events-*.jsonl").OrderBy(x=>x)){DateTime day;if(!DateTime.TryParse(Path.GetFileNameWithoutExtension(p).Substring(7),out day)||day.Date<from.Date)continue;foreach(var line in File.ReadLines(p)){try{var f=Parse<Finding>(line);if(f.At.ToUniversalTime()>=from)all.Add(f);}catch{}}}return all.OrderByDescending(f=>f.At).Take(5000).ToList();}
  public void Prune(int days){foreach(string prefix in new[]{"history-","events-","process-","ai-","ai-device-","speedtests-","device-discovery-"})foreach(string p in System.IO.Directory.GetFiles(DirectoryPath,prefix+"*.jsonl")){DateTime d;if(DateTime.TryParseExact(Path.GetFileNameWithoutExtension(p).Substring(prefix.Length),"yyyy-MM-dd",System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.None,out d)&&d.Date<DateTime.UtcNow.AddDays(-days).Date)File.Delete(p);}}
 }
}


