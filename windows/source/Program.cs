using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Reflection;
[assembly:AssemblyTitle("NetScope 上网助手")]
[assembly:AssemblyDescription("网络记录、小白体检与 Codex 分析")]
[assembly:AssemblyVersion("0.2.0.0")]
namespace NetScope {
 static class Program {
  [STAThread] static int Main(string[] args){if(args.Length==3&&args[0]=="--traffic-helper"){int parent;if(!Int32.TryParse(args[2],out parent))return 2;ProcessTrafficCollector.Run(args[1],parent);return 0;}string data=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"NetScope");for(int i=0;i<args.Length-1;i++)if(args[i]=="--data")data=Path.GetFullPath(args[i+1]);
   if(args.Contains("--collect-once")||args.Contains("--ai-smoke")){try{return Collect(data,args.Contains("--ai-smoke")).GetAwaiter().GetResult();}catch(Exception e){Directory.CreateDirectory(data);File.WriteAllText(Path.Combine(data,"failure.txt"),e.ToString());return 1;}}
   bool created;using(var mutex=new Mutex(true,"Local\\NetScope-Observer-"+Environment.UserName,out created)){if(!created){MessageBox.Show("NetScope 已在运行，请从右下角托盘图标打开。","NetScope");return 0;}
    Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);Application.ThreadException+=(o,e)=>MessageBox.Show("遇到错误："+e.Exception.Message+"\n已有记录保存在本机，请重新打开程序。","NetScope",MessageBoxButtons.OK,MessageBoxIcon.Warning);
    try{using(var controller=new AppController(data)){var form=new MainForm(controller);if(args.Contains("--refresh-ai"))form.Shown+=async delegate{try{await Task.Delay(1000);await controller.RunCheckAsync();for(int wait=0;wait<30&&controller.CurrentFrame==null;wait++)await Task.Delay(1000);if(controller.CurrentFrame!=null)await controller.AnalyzeWithCodexAsync();}catch(Exception ex){MessageBox.Show(form,"新版 AI 暂时没完成："+ex.Message+"\n原始记录仍保存在本机。","NetScope");}};Application.Run(form);}return 0;}catch(Exception e){MessageBox.Show("无法启动 NetScope："+e.Message,"NetScope");return 1;}}
  }
  static async Task<int> Collect(string data,bool ai){using(var c=new AppController(data)){var s=c.Settings;s.AiAutoEnabled=false;c.SaveSettings(s);await c.RunCheckAsync();await c.RefreshDevicesAsync();File.WriteAllText(Path.Combine(data,"smoke-frame.json"),Store.Json(c.CurrentFrame));File.WriteAllText(Path.Combine(data,"smoke-local.json"),Store.Json(c.CurrentLocal));File.WriteAllText(Path.Combine(data,"smoke-devices.json"),Store.Json(c.Devices));File.WriteAllText(Path.Combine(data,"smoke-connections.json"),Store.Json(c.Connections));File.WriteAllText(Path.Combine(data,"smoke-anonymous.txt"),c.BuildReport(true));c.ExportReport(Path.Combine(data,"smoke-report.txt"));c.ExportHistoryCsv(Path.Combine(data,"smoke-history.csv"),TimeSpan.FromDays(1));if(ai){await c.AnalyzeWithCodexAsync();c.ExportReport(Path.Combine(data,"smoke-report.txt"));}return c.CurrentFrame!=null?0:2;}}
 }
}

