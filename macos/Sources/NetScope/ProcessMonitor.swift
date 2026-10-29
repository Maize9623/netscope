import Foundation

struct ProcessTrafficRow: Codable, Identifiable {
    var id: String; var pid: Int; var name: String
    var downloadBps: Double; var uploadBps: Double; var observedSharePercent: Double
    var receivedBytes: UInt64? = nil; var sentBytes: UInt64? = nil
}
struct ProcessTrafficBytes: Codable, Identifiable {
    var id: String; var pid: Int; var name: String; var receivedBytes: UInt64; var sentBytes: UInt64
}
struct ProcessTrafficSnapshot: Codable {
    var at: Date; var intervalSeconds: Double; var state: String; var note: String; var rows: [ProcessTrafficRow]
    var observedBytes: [ProcessTrafficBytes]? = nil
    var timingBasis: String? = nil
    var intervalIsApproximate: Bool? = nil
}

/// nettop's actual CSV has a repeated empty-name header and no timestamp.
/// Receipt timing is measured outside parsing; a buffered double-header does
/// not silently turn the requested one-second delay into a measured interval.
private final class NettopHeaderClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: [UInt64] = []
    func observe(_ line: String) {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.first == "", fields.contains("bytes_in"), fields.contains("bytes_out") else { return }
        lock.lock(); defer { lock.unlock() }
        if ticks.count < 3 { ticks.append(DispatchTime.now().uptimeNanoseconds) }
    }
    var interval: Double? {
        lock.lock(); defer { lock.unlock() }
        guard ticks.count == 2, ticks[1] > ticks[0] else { return nil }
        let value = Double(ticks[1] - ticks[0]) / 1_000_000_000
        return value >= 0.2 && value <= 10 ? value : nil
    }
}

enum ProcessMonitor {
    static func capture() async throws -> ProcessTrafficSnapshot {
        let clock = NettopHeaderClock()
        let result = try await CodexCommand.run(path: "/usr/bin/nettop",
            arguments: ["-P","-L","2","-s","1","-n","-x","-J","bytes_in,bytes_out"],
            input: Data(), timeout: 8, lineHandler: { line, _ in clock.observe(line); return false })
        guard result.exitCode == 0 else {
            return ProcessTrafficSnapshot(at: Date(), intervalSeconds: 0, state: "unknown",
                note: "系统这次没有提供逐程序用量。不会据此判断某个程序没联网，也不会自动提权。", rows: [])
        }
        return parse(result.stdout, observedInterval: clock.interval)
    }

    // Accept documented timestamp fixtures as well as the actual repeated-header
    // CSV observed on macOS 15. The latter requires separately observed timing.
    static func parse(_ text: String, at: Date = Date(), observedInterval: Double? = nil) -> ProcessTrafficSnapshot {
        struct Counter { var pid: Int; var name: String; var received: UInt64; var sent: UInt64 }
        struct Sample { var stamp: String; var seconds: Double?; var values: [String: Counter] }
        var receiveIndex: Int?, sendIndex: Int?
        var timestamped = false, headerMode = false
        var samples: [Sample] = []
        var invalidRows = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = csv(String(line)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let receive = fields.firstIndex(of: "bytes_in"), let send = fields.firstIndex(of: "bytes_out") {
                receiveIndex = receive; sendIndex = send
                if fields.first == "time" && fields.count > 1 && fields[1] == "process" {
                    timestamped = true
                } else if fields.first == "" && !timestamped {
                    headerMode = true
                    samples.append(Sample(stamp: "header-\(samples.count)", seconds: nil, values: [:]))
                }
                continue
            }
            guard let receiveIndex, let sendIndex, fields.count > max(receiveIndex,sendIndex) else { continue }
            let label: String
            if timestamped {
                guard fields.count >= 2, let seconds = clockSeconds(fields[0]) else { continue }
                if samples.last?.stamp != fields[0] {
                    samples.append(Sample(stamp: fields[0], seconds: seconds, values: [:]))
                }
                label = fields[1]
            } else {
                guard headerMode, !samples.isEmpty else { continue }
                label = fields[0]
            }
            guard let dot = label.lastIndex(of: "."), let pid = Int(label[label.index(after: dot)...]), pid >= 0 else { continue }
            guard let received = UInt64(fields[receiveIndex]), let sent = UInt64(fields[sendIndex]) else { invalidRows += 1; continue }
            let name = String(label[..<dot]); guard !name.isEmpty else { continue }
            if samples[samples.count-1].values[label] != nil { invalidRows += 1; continue }
            samples[samples.count-1].values[label] = Counter(pid: pid, name: name, received: received, sent: sent)
        }
        func unknown(_ reason: String, bytes: [ProcessTrafficBytes] = []) -> ProcessTrafficSnapshot {
            ProcessTrafficSnapshot(at: at, intervalSeconds: 0, state: "unknown", note: reason, rows: [],
                                   observedBytes: bytes, timingBasis: "无法确定可比较的时间窗口", intervalIsApproximate: true)
        }
        guard samples.count == 2 else { return unknown("系统没有返回两次可比较的逐程序记录，暂时不知道哪个程序用了多少网。") }
        let before = samples[0], after = samples[1]
        var bytes: [ProcessTrafficBytes] = [], skipped = invalidRows
        for (key, value) in after.values {
            guard let old = before.values[key], value.received >= old.received, value.sent >= old.sent else { skipped += 1; continue }
            bytes.append(ProcessTrafficBytes(id: key, pid: value.pid, name: value.name,
                receivedBytes: value.received-old.received, sentBytes: value.sent-old.sent))
        }
        guard !bytes.isEmpty else { return unknown("还没有可比较的程序记录，等待下一次检查；不能把它理解成所有程序都没联网。") }
        let interval: Double
        if let first = before.seconds, let last = after.seconds {
            var measured = last-first
            if measured < -86_000 { measured += 86_400 }
            interval = measured
        } else if let observedInterval { interval = observedInterval }
        else {
            return unknown("已保留两轮实际字节差，但输出缓冲使采样时间无法分辨；速度未知，不能按请求的一秒冒充实测窗口。", bytes: bytes)
        }
        guard interval.isFinite, interval >= 0.2, interval <= 10 else {
            return unknown("这次逐程序记录间隔不正常，已保留字节差并放弃速度计算。", bytes: bytes)
        }
        var rows = bytes.map { value in
            ProcessTrafficRow(id: value.id, pid: value.pid, name: value.name,
                downloadBps: Double(value.receivedBytes)/interval, uploadBps: Double(value.sentBytes)/interval,
                observedSharePercent: 0, receivedBytes: value.receivedBytes, sentBytes: value.sentBytes)
        }
        let total = rows.reduce(0) { $0+$1.downloadBps+$1.uploadBps }
        for index in rows.indices { rows[index].observedSharePercent = total > 0 ? (rows[index].downloadBps+rows[index].uploadBps)/total*100 : 0 }
        rows.sort { $0.downloadBps+$0.uploadBps > $1.downloadBps+$1.uploadBps }
        let approximate = !timestamped
        let basis = approximate ? "两轮表头到达的单调时钟差，收集窗口近似" : "输出时间字段的样本间隔"
        return ProcessTrafficSnapshot(at: at, intervalSeconds: interval, state: skipped > 0 ? "partial" : "measured",
            note: "只比较系统这次显示的程序；比例是这些记录之间的占比，不是占满宽带的比例。VPN 和应用可能重复计算，刚启动/关闭或计数重置的程序可能漏记。" +
                  (approximate ? String(format: "约 %.2f 秒收集窗口的近似平均速度，不是内核精准瞬时速率；已保留实际字节差。", interval) : "") +
                  (skipped > 0 ? "本次有 \(skipped) 项不能比较。" : ""),
            rows: rows, observedBytes: bytes, timingBasis: basis, intervalIsApproximate: approximate)
    }
    private static func clockSeconds(_ value: String) -> Double? {
        let parts = value.split(separator: ":")
        guard parts.count == 3, let hour=Double(parts[0]),let minute=Double(parts[1]),let second=Double(parts[2]),
              (0..<24).contains(hour),(0..<60).contains(minute),(0..<60).contains(second) else { return nil }
        return hour*3600+minute*60+second
    }
    private static func csv(_ line: String) -> [String] {
        var fields: [String]=[],field="",quoted=false
        let chars=Array(line);var index=0
        while index<chars.count {
            let char=chars[index]
            if char == "\"" {
                if quoted && index+1<chars.count && chars[index+1] == "\"" { field.append("\"");index+=1 }
                else { quoted.toggle() }
            } else if char == "," && !quoted {fields.append(field);field=""}
            else {field.append(char)}
            index+=1
        }
        fields.append(field);return fields
    }
}
