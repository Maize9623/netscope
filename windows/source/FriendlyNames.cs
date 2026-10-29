using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
namespace NetScope {
 public static class FriendlyNames {
  static readonly object Sync=new object();
  static readonly Dictionary<string,string> Cache=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
  static readonly Dictionary<string,string> Known=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase){
   {"chrome","Google Chrome 浏览器"},{"msedge","Microsoft Edge 浏览器"},{"firefox","Firefox 浏览器"},{"opera","Opera 浏览器"},{"brave","Brave 浏览器"},
   {"wechat","微信"},{"weixin","微信"},{"qq","QQ"},{"qqnt","QQ"},{"dingtalk","钉钉"},{"feishu","飞书"},{"lark","飞书"},{"wxwork","企业微信"},
   {"cursor","Cursor"},{"code","Visual Studio Code"},{"codex","Codex AI"},{"windsurf","Windsurf"},{"claude","Claude"},{"chatgpt","ChatGPT"},
   {"onedrive","OneDrive 同步"},{"dropbox","Dropbox 同步"},{"baidunetdisk","百度网盘"},{"thunder","迅雷"},{"qbittorrent","qBittorrent 下载"},
   {"steam","Steam"},{"steamwebhelper","Steam 界面"},{"epicgameslauncher","Epic 游戏平台"},{"discord","Discord"},{"teams","Microsoft Teams"},{"ms-teams","Microsoft Teams"},
   {"clash","Clash 网络代理"},{"clash-verge","Clash Verge"},{"clash-meta","Mihomo 网络代理"},{"mihomo","Mihomo 网络代理"},{"v2rayn","v2rayN"},{"xray","Xray 网络代理"},{"sing-box","sing-box 网络代理"},{"hiddify","Hiddify"},
   {"svchost","Windows 后台服务"},{"system","Windows 系统"},{"searchhost","Windows 搜索"},{"searchapp","Windows 搜索"},{"explorer","Windows 文件管理器"},{"msmpeng","Windows 安全防护"},
   {"netscope","NetScope 网络助手"},{"netscope-beginner","NetScope 网络助手"},{"node","Node.js 后台程序"},{"python","Python 后台程序"},{"pythonw","Python 后台程序"},{"powershell","PowerShell"},{"pwsh","PowerShell"}
  };
  public static string ProcessLabel(string raw,int pid){
   string name=Path.GetFileNameWithoutExtension(raw??"");string label;
   if(Known.TryGetValue(name,out label))return label;
   string key=pid.ToString()+"|"+name;
   lock(Sync){if(Cache.TryGetValue(key,out label))return label;}
   label=String.IsNullOrWhiteSpace(name)?"未知软件":name;
   if(pid>0)try{using(var p=Process.GetProcessById(pid)){if(String.Equals(p.ProcessName,name,StringComparison.OrdinalIgnoreCase)){string file=p.MainModule.FileName;var info=FileVersionInfo.GetVersionInfo(file);string description=info.FileDescription;if(!String.IsNullOrWhiteSpace(description)&&description.Length<=80)label=description.Trim();}}}catch{}
   lock(Sync){if(Cache.Count>=512)Cache.Clear();Cache[key]=label;}
   return label;
  }
  public static string DeviceType(DeviceInfo device){
   if(device==null)return "未知";
   string hints=((device.Hint??"")+" "+(device.ReportedHint??"")+" "+(device.Name??"")+" "+(device.ReportedName??"")).ToLowerInvariant();
   if(Contains(hints,"iphone","android","galaxy","redmi","手机","pixel phone"))return "手机";
   if(Contains(hints,"ipad","tablet","平板"))return "平板";
   if(Contains(hints,"macbook","mac mini","macmini","imac","desktop-","laptop-","windows","电脑","笔记本"))return "电脑";
   if(Contains(hints,"router","gateway","路由器","网关"))return "路由器";
   if(Contains(hints,"printer","打印机"))return "打印机";
   if(Contains(hints,"电视","smart tv","appletv","apple-tv"))return "电视";
   if(Contains(hints,"nas","synology","群晖"))return "存储设备";
   if(device.Source!=null&&device.Source.Contains("本机"))return "电脑";
   return "未知";
  }
  public static string DeviceGuess(DeviceInfo device){
   string type=DeviceType(device);
   bool manual=device!=null&&((device.NameSource??"").Contains("手动")||(device.NameSource??"").Contains("标签"));
   return type=="未知"?"还不知道是什么设备":manual?"你标记的"+type:"可能是"+type;
  }
  static bool Contains(string text,params string[] values){foreach(string value in values)if(text.Contains(value))return true;return false;}
 }
}
