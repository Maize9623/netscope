import Foundation
import Darwin
import SystemConfiguration

actor NetworkMonitor {
    private struct Baseline { let received: UInt64; let sent: UInt64; let tick: UInt64; let up: Bool }
    private var baselines: [String: Baseline] = [:]
    private var lastLocal: LocalSample?
    private var lastSelection = ""
    private var lastCaptureTick: UInt64 = 0

    func captureLocal(selectedAdapterID: String) -> LocalSample {
        let now = DispatchTime.now().uptimeNanoseconds
        if selectedAdapterID == lastSelection, let recent = lastLocal, now >= lastCaptureTick,
           now - lastCaptureTick < 50_000_000 { return recent }
        let read = InterfaceReader.read()
        var adapters = read.adapters
        for index in adapters.indices {
            let item = adapters[index]
            guard read.validCounters.contains(item.id) else { baselines.removeValue(forKey: item.id); continue }
            if let old = baselines[item.id], old.up, item.isUp, now >= old.tick {
                let rates = BackendMath.counterRates(previousReceived: old.received, previousSent: old.sent,
                    received: item.receivedBytes, sent: item.sentBytes, elapsed: Double(now - old.tick) / 1_000_000_000)
                adapters[index].downloadBps = rates.download
                adapters[index].uploadBps = rates.upload
            }
            baselines[item.id] = Baseline(received: item.receivedBytes, sent: item.sentBytes, tick: now, up: item.isUp)
        }
        let ids = Set(adapters.map(\.id))
        baselines = baselines.filter { ids.contains($0.key) }
        var sample = LocalSample()
        sample.at = Date(); sample.adapters = adapters; sample.proxySummary = read.metadata.proxySummary
        let automatic = selectedAdapterID.isEmpty || selectedAdapterID == "auto"
        var chosen = automatic ? nil : adapters.first { $0.id == selectedAdapterID }
        if chosen == nil {
            let candidates = adapters.filter { $0.isUp && !$0.isVirtual && !$0.gateways.isEmpty }
            chosen = candidates.first { $0.id == read.metadata.primaryInterface } ?? candidates.sorted { $0.id < $1.id }.first
        }
        if let selected = chosen {
            sample.trafficAdapterID = selected.id
            sample.trafficAdapterName = selected.name + (automatic ? "（自动选择，非逐目标路径证明）" : "（仅所选接口计数）")
            if !automatic && selected.id != selectedAdapterID { sample.trafficAdapterName += "；原接口不存在，已回退自动选择" }
            sample.downloadBps = selected.downloadBps; sample.uploadBps = selected.uploadBps
            sample.trafficRateReady = selected.downloadBps != nil && selected.uploadBps != nil
            sample.gateway = selected.gateways.first
        } else { sample.trafficAdapterName = "无启用且带网关的疑似物理接口；可手动选择" }
        lastLocal = sample; lastSelection = selectedAdapterID; lastCaptureTick = now
        return sample
    }

    func probe(targets: [ProbeTarget], timeoutSeconds: Int) async -> [ProbeResult] {
        let enabled = targets.filter(\.enabled)
        guard !enabled.isEmpty else { return [] }
        let timeout = TimeInterval(min(20, max(3, timeoutSeconds)))
        // Read configuration afresh without consuming the two-second traffic baseline.
        let pathRead = InterfaceReader.read()
        let context = NetworkPathContext.make(selectedAdapterID: lastLocal?.trafficAdapterID ?? "unknown",
                                              adapters: pathRead.adapters, metadata: pathRead.metadata)
        return await withTaskGroup(of: (Int, ProbeResult).self, returning: [ProbeResult].self) { group in
            var next = 0
            var answers = Array<ProbeResult?>(repeating: nil, count: enabled.count)
            while next < min(4, enabled.count) {
                let index = next, target = enabled[index]; next += 1
                group.addTask { (index, await HTTPHeadProbe(target: target, timeout: timeout, context: context).run()) }
            }
            while let (index, result) = await group.next() {
                answers[index] = result
                if next < enabled.count {
                    let nextIndex = next, target = enabled[nextIndex]; next += 1
                    group.addTask { (nextIndex, await HTTPHeadProbe(target: target, timeout: timeout, context: context).run()) }
                }
            }
            return answers.compactMap { $0 }
        }
    }

    func snapshot(settings: AppSettings) async -> MonitorFrame {
        let tick = DispatchTime.now().uptimeNanoseconds
        let local: LocalSample
        if lastSelection == settings.trafficAdapterID, let recent = lastLocal,
           tick >= lastCaptureTick, tick - lastCaptureTick <= 2_500_000_000 {
            local = recent
        } else { local = captureLocal(selectedAdapterID: settings.trafficAdapterID) }
        let results = await probe(targets: settings.targets, timeoutSeconds: settings.timeoutSeconds)
        // ICMP has not been measured. A nil gateway value must not be read as failure.
        return MonitorFrame(at: Date(), local: local, probes: results, gatewayMs: nil, findings: [])
    }
}

struct SystemNetworkMetadata {
    var primaryInterface = ""
    var gateways: [String: [String]] = [:]
    var dns: [String: [String]] = [:]
    var proxySummary = "系统代理配置不可读"

    static func read() -> SystemNetworkMetadata {
        var result = SystemNetworkMetadata()
        guard let store = SCDynamicStoreCreate(nil, "NetScope" as CFString, nil, nil) else { return result }
        func dictionary(_ key: String) -> [String: Any] {
            (SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]) ?? [:]
        }
        let global = dictionary("State:/Network/Global/IPv4")
        result.primaryInterface = global["PrimaryInterface"] as? String ?? dictionary("State:/Network/Global/IPv6")["PrimaryInterface"] as? String ?? ""
        let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv[46]" as CFString) as? [String] ?? []
        for key in keys {
            let data = dictionary(key)
            guard let interface = data["InterfaceName"] as? String else { continue }
            if let router = data["Router"] as? String, !router.isEmpty {
                if !(result.gateways[interface] ?? []).contains(router) { result.gateways[interface, default: []].append(router) }
            }
            let pieces = key.split(separator: "/")
            if pieces.count >= 4 {
                let servers = dictionary("State:/Network/Service/\(pieces[3])/DNS")["ServerAddresses"] as? [String] ?? []
                result.dns[interface] = Array(Set((result.dns[interface] ?? []) + servers)).sorted()
            }
        }
        let proxy = SCDynamicStoreCopyProxies(store) as? [String: Any] ?? [:]
        var descriptions: [String] = []
        for scheme in ["HTTP", "HTTPS", "SOCKS"] {
            if (proxy[scheme + "Enable"] as? NSNumber)?.boolValue == true {
                let host = proxy[scheme + "Proxy"] as? String ?? "未知地址"
                let port = (proxy[scheme + "Port"] as? NSNumber)?.stringValue ?? "?"
                descriptions.append("\(scheme)代理 \(host):\(port)")
            }
        }
        if (proxy["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true {
            let address = proxy["ProxyAutoConfigURLString"] as? String ?? ""
            descriptions.append("PAC已配置：" + (URL(string: address)?.host ?? "地址省略"))
        }
        if (proxy["ProxyAutoDiscoveryEnable"] as? NSNumber)?.boolValue == true { descriptions.append("自动发现代理已配置") }
        if descriptions.isEmpty { descriptions.append("未发现已启用的显式系统代理") }
        result.proxySummary = descriptions.joined(separator: "；") + "；配置不证明实际路径，VPN/TUN仍可能介入"
        return result
    }
}

struct InterfaceReadResult {
    var adapters: [AdapterInfo] = []
    var validCounters: Set<String> = []
    var metadata = SystemNetworkMetadata()
}

enum InterfaceReader {
    static func read() -> InterfaceReadResult {
        var result = InterfaceReadResult(); result.metadata = SystemNetworkMetadata.read()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(first) }
        var items: [String: AdapterInfo] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let record = current.pointee
            defer { cursor = record.ifa_next }
            guard let namePointer = record.ifa_name, let address = record.ifa_addr else { continue }
            let name = String(cString: namePointer)
            var item = items[name] ?? AdapterInfo(id: name, name: name, description: "macOS 系统接口 " + name)
            item.isVirtual = isProbablyVirtual(name)
            item.isUp = record.ifa_flags & UInt32(IFF_UP) != 0 && record.ifa_flags & UInt32(IFF_RUNNING) != 0
            item.status = item.isUp ? "Up" : "Down"
            let family = Int32(address.pointee.sa_family)
            if family == AF_LINK {
                let link = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee
                item.type = "链路类型 \(link.sdl_type)" + (item.isVirtual ? "（疑似虚拟/隧道）" : "")
                let offset = 8 + Int(link.sdl_nlen), length = Int(link.sdl_alen)
                if length > 0, length <= 32, Int(link.sdl_len) >= offset + length {
                    let bytes = UnsafeRawPointer(address).advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                    item.mac = (0..<length).map { String(format: "%02x", bytes[$0]) }.joined(separator: ":")
                }
                if let pointer = record.ifa_data {
                    let data = pointer.assumingMemoryBound(to: if_data.self).pointee
                    // getifaddrs provides if_data with potentially 32-bit counters.
                    // Rates are accepted only from the separate 64-bit route-table snapshot.
                    item.linkMbps = data.ifi_baudrate > 0 ? Double(data.ifi_baudrate) / 1_000_000 : nil
                }
            } else if family == AF_INET || family == AF_INET6 {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = buffer.withUnsafeMutableBufferPointer { chars in
                    getnameinfo(address, socklen_t(address.pointee.sa_len), chars.baseAddress, socklen_t(chars.count), nil, 0, NI_NUMERICHOST)
                }
                if status == 0 {
                    let value = String(cString: buffer)
                    if !item.addresses.contains(value) { item.addresses.append(value) }
                }
            }
            item.gateways = result.metadata.gateways[name] ?? []
            item.dnsServers = result.metadata.dns[name] ?? []
            items[name] = item
        }
        for (name, counters) in InterfaceCounters64.read() {
            guard var item = items[name] else { continue }
            item.receivedBytes = counters.received; item.sentBytes = counters.sent
            if counters.baudrate > 0 { item.linkMbps = Double(counters.baudrate) / 1_000_000 }
            items[name] = item; result.validCounters.insert(name)
        }
        result.adapters = items.values.sorted { lhs, rhs in
            if lhs.isUp != rhs.isUp { return lhs.isUp }
            if lhs.isVirtual != rhs.isVirtual { return !lhs.isVirtual }
            return lhs.id < rhs.id
        }
        return result
    }
    static func isProbablyVirtual(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["lo", "utun", "tun", "tap", "ppp", "ipsec", "gif", "stf", "bridge", "vmnet", "vmenet", "vbox", "awdl", "llw", "p2p", "anpi"].contains { lower.hasPrefix($0) }
    }
}

