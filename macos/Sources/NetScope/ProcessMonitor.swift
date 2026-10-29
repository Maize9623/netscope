import Foundation

struct ProcessTrafficRow: Codable, Identifiable {
    var id: String; var pid: Int; var name: String
    var downloadBps: Double; var uploadBps: Double; var observedSharePercent: Double
}
struct ProcessTrafficSnapshot: Codable {
    var at: Date; var intervalSeconds: Double; var state: String; var note: String; var rows: [ProcessTrafficRow]
}
enum ProcessMonitor {
    static func capture() async throws -> ProcessTrafficSnapshot {
        let result = try await CodexCommand.run(path: "/usr/bin/nettop", arguments: ["-P","-L","2","-s","1","-n","-x","-J","bytes_in,bytes_out"], input: Data(), timeout: 8)
        guard result.exitCode == 0 else {
            return ProcessTrafficSnapshot(at: Date(), intervalSeconds: 0, state: "unknown", note: "系统这次没有提供逐程序用量。不会据此判断某个程序没联网，也不会自动提权。", rows: [])
        }
        return parse(result.stdout)
    }
    // Parse only nettop per-process cumulative byte counters. Never estimate bytes from connections.
    static func parse(_ text: String, at: Date = Date()) -> ProcessTrafficSnapshot {
        struct Counter { var pid: Int; var name: String; var received: UInt64; var sent: UInt64 }
        var receiveIndex: Int?, sendIndex: Int?
        var samples: [(stamp: String, seconds: Double, values: [String: Counter])] = []
        var invalidRows = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = csv(String(line))
            if let receive = fields.firstIndex(of: "bytes_in"), let send = fields.firstIndex(of: "bytes_out") { receiveIndex = receive; sendIndex = send; continue }
            guard let receiveIndex, let sendIndex, fields.count > max(receiveIndex,sendIndex), fields.count >= 2,
                  let seconds = clockSeconds(fields[0]) else { continue }
            let label = fields[1].trimmingCharacters(in: .whitespaces)
            guard let dot = label.lastIndex(of: "."), let pid = Int(label[label.index(after: dot)...]), pid >= 0 else { continue }
            guard let received = UInt64(fields[receiveIndex]), let sent = UInt64(fields[sendIndex]) else { invalidRows += 1; continue }
            if samples.last?.stamp != fields[0] { samples.append((fields[0],seconds,[:])) }
            let name = String(label[..<dot]); guard !name.isEmpty else { continue }
            samples[samples.count-1].values[label] = Counter(pid: pid,name: name,received: received,sent: sent)
        }
        func unknown(_ reason: String) -> ProcessTrafficSnapshot { ProcessTrafficSnapshot(at: at,intervalSeconds: 0,state: "unknown",note: reason,rows: []) }
        guard samples.count == 2 else { return unknown("系统没有返回两次可比较的逐程序记录，暂时不知道哪个程序用了多少网。") }
        let before = samples[0], after = samples[1]
        var interval = after.seconds-before.seconds
        if interval < -86_000 { interval += 86_400 }
        guard interval >= 0.2, interval <= 10 else { return unknown("这次逐程序记录间隔不正常，已放弃计算，避免显示错误速度。") }
        var rows: [ProcessTrafficRow] = [], skipped = invalidRows
        for (key,value) in after.values {
            guard let old = before.values[key], value.received >= old.received, value.sent >= old.sent else { skipped += 1; continue }
            rows.append(ProcessTrafficRow(id: key,pid: value.pid,name: value.name,downloadBps: Double(value.received-old.received)/interval,uploadBps: Double(value.sent-old.sent)/interval,observedSharePercent: 0))
        }
        guard !rows.isEmpty else { return unknown("还没有可比较的程序记录，等待下一次检查；不能把它理解成所有程序都没联网。") }
        let total = rows.reduce(0) { $0+$1.downloadBps+$1.uploadBps }
        for index in rows.indices { rows[index].observedSharePercent = total > 0 ? (rows[index].downloadBps+rows[index].uploadBps)/total*100 : 0 }
        rows.sort { $0.downloadBps+$0.uploadBps > $1.downloadBps+$1.uploadBps }
        return ProcessTrafficSnapshot(at:at,intervalSeconds:interval,state:skipped > 0 ? "partial" : "measured",note:"只比较系统这次显示的程序；比例是这些记录之间的占比，不是占满宽带的比例。VPN 和应用可能重复计算，刚启动/关闭或计数重置的程序可能漏记。"+(skipped > 0 ? "本次有 \(skipped) 项不能比较。" : ""),rows:rows)
    }
    private static func clockSeconds(_ value: String) -> Double? {
        let parts = value.split(separator: ":")
        guard parts.count == 3, let hour=Double(parts[0]),let minute=Double(parts[1]),let second=Double(parts[2]), (0..<24).contains(hour),(0..<60).contains(minute),(0..<60).contains(second) else { return nil }
        return hour*3600+minute*60+second
    }
    private static func csv(_ line: String) -> [String] {
        var fields: [String]=[],field="",quoted=false
        let chars=Array(line);var index=0
        while index<chars.count {
            let char=chars[index]
            if char == "\"" { if quoted && index+1<chars.count && chars[index+1] == "\"" {field.append("\"");index+=1} else {quoted.toggle()} }
            else if char == "," && !quoted {fields.append(field);field=""}
            else {field.append(char)}
            index+=1
        }
        fields.append(field);return fields
    }
}
