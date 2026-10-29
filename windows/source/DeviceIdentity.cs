using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace NetScope {
 // Called only from the explicit "identify known device names" UI action.
 // A supplied network name is evidence about naming, never a person's identity.
 public static class DeviceIdentity {
  public const string NetworkNameSource = "网络名称（对方/网络提供，未核实主人）";
  static readonly DeviceNameResolver Resolver = new DeviceNameResolver(
   address => Dns.GetHostEntryAsync(address).ContinueWith(task => {
    // Observe errors here; .NET Framework offers no cancellable DNS operation.
    if (task.IsFaulted) { var observed=task.Exception; return null; }
    return task.Status==TaskStatus.RanToCompletion ? task.Result.HostName : null;
   }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default), 2000);

  public static Task<List<DeviceInfo>> ResolveNamesAsync(List<DeviceInfo> devices) {
   return Resolver.ResolveNamesAsync(devices);
  }
 }

 // Bounded state is deliberately shared across button clicks. A timed-out DNS
 // operation still holds one of the two pending positions until it really ends.
 internal sealed class DeviceNameResolver {
  sealed class CacheEntry { internal string Name; internal DateTime Expires; internal DateTime At; }
  readonly object gate=new object();
  readonly Dictionary<string,Task<string>> pending=new Dictionary<string,Task<string>>(StringComparer.Ordinal);
  readonly Dictionary<string,CacheEntry> cache=new Dictionary<string,CacheEntry>(StringComparer.Ordinal);
  readonly SemaphoreSlim batchGate=new SemaphoreSlim(1,1);
  readonly Func<IPAddress,Task<string>> lookup;
  readonly int timeoutMilliseconds;
  internal DeviceNameResolver(Func<IPAddress,Task<string>> lookup,int timeoutMilliseconds) {
   if(lookup==null)throw new ArgumentNullException("lookup");
   this.lookup=lookup;this.timeoutMilliseconds=Math.Max(1,Math.Min(2000,timeoutMilliseconds));
  }
  internal int PendingCount { get { lock(gate)return pending.Count; } }
  internal int CacheCount { get { lock(gate)return cache.Count; } }

  internal async Task<List<DeviceInfo>> ResolveNamesAsync(List<DeviceInfo> devices) {
   var rows=(devices??new List<DeviceInfo>()).Where(x=>x!=null).Select(Clone).ToList();
   // Do not accumulate simultaneous complete batches from repeated UI clicks.
   if(!await batchGate.WaitAsync(0).ConfigureAwait(false))return rows;
   try {
    var selected=new List<DeviceInfo>();var seen=new HashSet<string>(StringComparer.Ordinal);
    foreach(var row in rows) {
     IPAddress address;if(!Eligible(row,out address))continue;
     if(seen.Add(Key(row,address)))selected.Add(row);
     if(selected.Count>=32)break;
    }
    for(int index=0;index<selected.Count;index+=2) {
     var jobs=new List<Task>();
     jobs.Add(ResolveRowAsync(selected[index]));
     if(index+1<selected.Count)jobs.Add(ResolveRowAsync(selected[index+1]));
     await Task.WhenAll(jobs).ConfigureAwait(false);
    }
    // Repeated display rows for the exact same observed interface/IP/MAC share
    // the result but keep their own original record/source and manual label.
    var named=selected.Where(x=>x.ReportedNameSource==DeviceIdentity.NetworkNameSource)
      .GroupBy(x=>Key(x,IPAddress.Parse(x.Ip))).ToDictionary(x=>x.Key,x=>x.First().ReportedName);
    foreach(var row in rows) {
     IPAddress address;string name;
     if(Eligible(row,out address)&&named.TryGetValue(Key(row,address),out name))Apply(row,name);
    }
    return rows;
   } finally { batchGate.Release(); }
  }

  async Task ResolveRowAsync(DeviceInfo row) {
   IPAddress address;if(!Eligible(row,out address))return;
   string name=await GetNameAsync(Key(row,address),address).ConfigureAwait(false);
   if(name!=null)Apply(row,name);
  }
  async Task<string> GetNameAsync(string key,IPAddress address) {
   Task<string> task;
   lock(gate) {
    DateTime now=DateTime.UtcNow;
    foreach(var old in cache.Where(x=>x.Value.Expires<=now).Select(x=>x.Key).ToList())cache.Remove(old);
    CacheEntry cached;if(cache.TryGetValue(key,out cached))return cached.Name;
    if(!pending.TryGetValue(key,out task)) {
     // Both native operations may still be running after their UI deadlines.
     // Preserve unknown instead of creating abandoned operations or a long queue.
     if(pending.Count>=2)return null;
     try { task=lookup(address)??Task.FromResult<string>(null); }
     catch { task=Task.FromResult<string>(null); }
     pending[key]=task;
     task.ContinueWith(completed=> {
      string resolved=null;
      if(completed.IsFaulted){var observed=completed.Exception;}
      else if(completed.Status==TaskStatus.RanToCompletion)resolved=CleanName(completed.Result);
      lock(gate) {
       pending.Remove(key);
       while(cache.Count>=256)cache.Remove(cache.OrderBy(x=>x.Value.At).First().Key);
       var at=DateTime.UtcNow;
       cache[key]=new CacheEntry{Name=resolved,At=at,Expires=at.AddSeconds(resolved==null?30:600)};
      }
     },CancellationToken.None,TaskContinuationOptions.ExecuteSynchronously,TaskScheduler.Default);
    }
   }
   if(await Task.WhenAny(task,Task.Delay(timeoutMilliseconds)).ConfigureAwait(false)!=task)return null;
   try { return CleanName(await task.ConfigureAwait(false)); } catch { return null; }
  }

  static string Key(DeviceInfo row,IPAddress address) {
   // MAC and interface source prevent an IP reused by another observed device
   // from inheriting the previous name from our bounded ten-minute cache.
   return address.ToString()+"|"+(row.Mac??"").ToUpperInvariant()+"|"+(row.Source??"");
  }
  internal static bool Eligible(DeviceInfo row,out IPAddress address) {
   address=null;
   if(row==null||!IPAddress.TryParse(row.Ip,out address))return false;
   string source=row.Source??"";
   if(!source.StartsWith("Windows 邻居缓存",StringComparison.Ordinal)&&
      !source.StartsWith("Windows IPv4 ARP 缓存",StringComparison.Ordinal))return false;
   if(IPAddress.IsLoopback(address)||address.Equals(IPAddress.Any)||address.Equals(IPAddress.IPv6Any)||
      address.Equals(IPAddress.Broadcast)||address.IsIPv6Multicast)return false;
   if(address.AddressFamily==AddressFamily.InterNetwork) {
    byte first=address.GetAddressBytes()[0];if(first==0||first>=224)return false;
   }
   return true;
  }
  internal static string CleanName(string value) {
   if(String.IsNullOrWhiteSpace(value))return null;
   var name=value.Trim().TrimEnd('.');
   IPAddress numeric;
   if(name.Length==0||name.Length>253||IPAddress.TryParse(name,out numeric))return null;
   // A DNS label must not inject control characters or visual bidi overrides.
   foreach(char c in name)if(Char.IsControl(c)||Char.IsWhiteSpace(c)||c=='/'||c=='\\'||
      (c>='\u202a'&&c<='\u202e')||(c>='\u2066'&&c<='\u2069'))return null;
   return name;
  }
  static void Apply(DeviceInfo row,string name) {
   if(String.IsNullOrEmpty(name))return;
   bool manual=(row.NameSource??"").StartsWith("人工",StringComparison.Ordinal);
   row.ReportedName=name;row.ReportedNameSource=DeviceIdentity.NetworkNameSource;
   if(!manual){row.Name=name;row.NameSource=DeviceIdentity.NetworkNameSource;}
  }
  internal static DeviceInfo Clone(DeviceInfo row) {
   return new DeviceInfo{Ip=row.Ip,Mac=row.Mac,Name=row.Name,ReportedName=row.ReportedName,
    Hint=row.Hint,ReportedHint=row.ReportedHint,NameSource=row.NameSource,ReportedNameSource=row.ReportedNameSource,State=row.State,Source=row.Source,
    DownloadBps=row.DownloadBps,UploadBps=row.UploadBps,ObservedAt=row.ObservedAt};
  }
 }
}

