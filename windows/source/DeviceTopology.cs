using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Text.RegularExpressions;
namespace NetScope {
 internal sealed class DeviceNetworkLocation {
  public string Scope="unknown",AdapterName="网络来源待确认";
  public int? InterfaceIndex;
  public bool IsGateway;
  public bool IsUp;
  public string Description {get{return Scope=="virtual"?"VPN / 虚拟连接「"+AdapterName+"」":Scope=="physical"?"Wi-Fi / 网线连接「"+AdapterName+"」":"网络来源待确认";}}
 }
 internal sealed class DeviceTopology {
  sealed class Entry {public string Name;public bool Virtual,Up,Physical;public List<IPAddress> Gateways=new List<IPAddress>();}
  readonly Dictionary<int,Entry> entries=new Dictionary<int,Entry>(); private static int Priority(Entry e){return (e.Up?10:0)+(e.Gateways.Count>0?60:0)+(e.Physical&&!e.Virtual?100:0)+(e.Virtual?0:20);} void Remember(int index,Entry entry){Entry old;if(!entries.TryGetValue(index,out old)||Priority(entry)>Priority(old))entries[index]=entry;}
  public static DeviceTopology Read(LocalSample current){var result=new DeviceTopology();try{foreach(var nic in NetworkInterface.GetAllNetworkInterfaces()){try{var properties=nic.GetIPProperties();var known=current==null?null:current.Adapters.FirstOrDefault(x=>String.Equals(x.Id,nic.Id,StringComparison.OrdinalIgnoreCase));var entry=new Entry{Name=known==null?nic.Name:known.Name,Virtual=known==null?NetworkCollector.IsProbablyVirtual(nic):known.IsVirtual,Up=known==null?nic.OperationalStatus==OperationalStatus.Up:known.IsUp,Physical=nic.NetworkInterfaceType==NetworkInterfaceType.Wireless80211||nic.NetworkInterfaceType==NetworkInterfaceType.Ethernet};entry.Gateways=properties.GatewayAddresses.Select(x=>x.Address).Where(x=>x!=null).ToList();try{var ipv4=properties.GetIPv4Properties();if(ipv4!=null)result.Remember(ipv4.Index,entry);}catch{}try{var ipv6=properties.GetIPv6Properties();if(ipv6!=null)result.Remember(ipv6.Index,entry);}catch{}}catch{}}}catch{}return result;}
  public DeviceNetworkLocation Locate(DeviceInfo device){var result=new DeviceNetworkLocation();if(device==null)return result;if((device.Source??"").StartsWith("本机接口",StringComparison.Ordinal)){result.Scope="local";result.AdapterName="这台电脑";return result;}var match=Regex.Match(device.Source??"",@"(?:^|[；;\s])接口\s+(\d+)");int index;if(!match.Success||!Int32.TryParse(match.Groups[1].Value,out index))return result;result.InterfaceIndex=index;Entry entry;if(!entries.TryGetValue(index,out entry))return result;result.AdapterName=entry.Name;result.IsUp=entry.Up;result.Scope=entry.Virtual?"virtual":entry.Physical&&entry.Up?"physical":"unknown";IPAddress address;if(IPAddress.TryParse(device.Ip,out address))result.IsGateway=entry.Gateways.Any(x=>x.Equals(address));return result;}
 }
}
