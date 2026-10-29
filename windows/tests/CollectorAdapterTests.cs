using System;
using System.Net.NetworkInformation;
using NetScope;
class CollectorAdapterTests {
 static int count;
 static void Check(bool expected,string name,string description,NetworkInterfaceType type){
  bool actual=NetworkCollector.IsProbablyVirtual(name,description,type);
  if(actual!=expected)throw new Exception("Adapter classification mismatch: "+name+" | "+description+" | "+type);
  count++;Console.WriteLine("PASS "+(expected?"software/virtual":"physical candidate")+" "+name+" "+description);
 }
 static void Main(){
  foreach(string text in new[]{"WAN Miniport (IP)","WAN Miniport (IPv6)","WAN Miniport (Network Monitor)",
   "WLAN-QoS Packet Scheduler","Native WiFi Filter Driver","Realtek NDIS LightWeight Filter",
   "Realtek NDIS Light Weight Filter","WFP Native MAC Layer LightWeight Filter",
   "WFP 802.3 MAC Layer LightWeight Filter","WFP 802.11 MAC Layer LightWeight Filter"}){
   Check(true,text,"",NetworkInterfaceType.Ethernet);
  }
  Check(true,"WLAN","Intel(R) Wi-Fi Native WiFi Filter Driver",NetworkInterfaceType.Wireless80211);
  Check(true,"wan\tminiport","",NetworkInterfaceType.Ethernet);
  Check(true,"LAN","NDIS Filter Driver",NetworkInterfaceType.Ethernet);
  Check(true,"Fastlink","Meta Tunnel",NetworkInterfaceType.Ethernet);
  Check(true,"TAP-Windows Adapter V9","",NetworkInterfaceType.Ethernet);
  Check(true,"tun0","",NetworkInterfaceType.Ethernet);
  Check(true,"Office VPN","",NetworkInterfaceType.Ethernet);
  Check(true,"vEthernet (Default Switch)","Hyper-V Virtual Ethernet Adapter",NetworkInterfaceType.Ethernet);
  Check(true,"Tunnel Adapter","Wintun Userspace Tunnel",NetworkInterfaceType.Ethernet);
  Check(true,"LAN","WireGuard Tunnel",NetworkInterfaceType.Ethernet);
  Check(true,null,null,NetworkInterfaceType.Tunnel);
  Check(true,null,null,NetworkInterfaceType.Ppp);
  Check(true,null,null,NetworkInterfaceType.Loopback);
  Check(false,"WLAN","Intel(R) Wi-Fi 6 AX201 160MHz",NetworkInterfaceType.Wireless80211);
  Check(false,"Ethernet","Realtek PCIe GbE Family Controller",NetworkInterfaceType.Ethernet);
  Check(false,"USB LAN","Realtek USB GbE Family Controller",NetworkInterfaceType.Ethernet);
  Check(false,"Ethernet","Killer E2600 Gigabit Ethernet Controller",NetworkInterfaceType.Ethernet);
  Check(false,"Tuning Lab Ethernet","Intel Ethernet Connection",NetworkInterfaceType.Ethernet);
  Check(false,"Laptop LAN","Intel Ethernet Controller",NetworkInterfaceType.Ethernet);
  Check(false,"Ethernet","Intel Ethernet Miniport",NetworkInterfaceType.Ethernet);
  Check(false,null,null,NetworkInterfaceType.Ethernet);
  Check(false,"WLAN","",NetworkInterfaceType.Wireless80211);
  if(!NetworkCollector.IsSoftwareLayer("Realtek NDIS LightWeight Filter",""))throw new Exception("Software layer note lost");
  count++;
  if(NetworkCollector.IsSoftwareLayer("Fastlink Meta Tunnel",""))throw new Exception("Tunnel incorrectly described as filter layer");
  count++;
  Console.WriteLine("RESULT "+count+" adapter classification checks passed; pure strings only, no network enumeration.");
 }
}
