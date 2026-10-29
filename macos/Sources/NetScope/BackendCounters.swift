import Foundation
import Darwin

/// A local configuration fingerprint, not proof of a VPN exit node or the whole
/// route. Addresses remain in local raw observations; only this ID is compared.
enum NetworkPathContext {
    static func make(selectedAdapterID: String, adapters: [AdapterInfo], metadata: SystemNetworkMetadata) -> String {
        var parts = ["selected=" + selectedAdapterID, "primary=" + metadata.primaryInterface,
                     "proxy=" + metadata.proxySummary]
        for item in adapters.filter({ $0.isUp || $0.id == selectedAdapterID }).sorted(by: { $0.id < $1.id }) {
            parts.append([item.id, item.isUp ? "up" : "down",
                          item.addresses.sorted().joined(separator: ","),
                          item.gateways.sorted().joined(separator: ","),
                          item.dnsServers.sorted().joined(separator: ",")].joined(separator: "|"))
        }
        return BackendHTTP.stableID(parts.joined(separator: "\n"))
    }
}

/// Public Darwin route sysctl supplies if_data64. Unlike getifaddrs' if_data,
/// these counters do not wrap after only 4 GiB. Failure means unavailable rates.
enum InterfaceCounters64 {
    struct Counters { let received: UInt64; let sent: UInt64; let baudrate: UInt64 }
    static func read() -> [String: Counters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        // Interface churn can enlarge the required buffer between the two reads.
        for _ in 0..<2 {
            var size = 0
            let sizeStatus = mib.withUnsafeMutableBufferPointer { values in
                sysctl(values.baseAddress, u_int(values.count), nil, &size, nil, 0)
            }
            guard sizeStatus == 0, size >= 4, size <= 16_777_216 else { return [:] }
            let allocation = size
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: allocation, alignment: MemoryLayout<if_msghdr2>.alignment)
            defer { buffer.deallocate() }
            let readStatus = mib.withUnsafeMutableBufferPointer { values in
                sysctl(values.baseAddress, u_int(values.count), buffer, &size, nil, 0)
            }
            if readStatus != 0 { if errno == ENOMEM { continue }; return [:] }
            guard size <= allocation else { return [:] }
            var answer: [String: Counters] = [:], offset = 0
            while offset + 4 <= size {
                let entry = UnsafeRawPointer(buffer.advanced(by: offset))
                // memcpy avoids relying on route-message alignment.
                var length: UInt16 = 0
                withUnsafeMutableBytes(of: &length) { bytes in
                    _ = memcpy(bytes.baseAddress!, entry, MemoryLayout<UInt16>.size)
                }
                let count = Int(length)
                guard count >= 4, offset + count <= size else { return [:] }
                let kind = entry.load(fromByteOffset: 3, as: UInt8.self)
                if Int32(kind) == RTM_IFINFO2, count >= MemoryLayout<if_msghdr2>.size {
                    var message = if_msghdr2()
                    withUnsafeMutableBytes(of: &message) { bytes in
                        _ = memcpy(bytes.baseAddress!, entry, bytes.count)
                    }
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    let valid = name.withUnsafeMutableBufferPointer { chars in
                        if_indextoname(UInt32(message.ifm_index), chars.baseAddress) != nil
                    }
                    if valid {
                        answer[String(cString: name)] = Counters(received: message.ifm_data.ifi_ibytes,
                            sent: message.ifm_data.ifi_obytes, baudrate: message.ifm_data.ifi_baudrate)
                    }
                }
                offset += count
            }
            return answer
        }
        return [:]
    }
}
