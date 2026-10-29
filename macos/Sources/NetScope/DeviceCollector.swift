import Foundation
import Darwin

enum DeviceCollector {
    /// arp -an and ndp -an only read existing caches; -n prevents reverse DNS.
    static func collect(labels: [String: String] = [:]) async throws -> [DeviceInfo] {
        async let arp = BackendCommand.run(executable: "/usr/sbin/arp", arguments: ["-an"], timeout: 3)
        async let ndp = BackendCommand.run(executable: "/usr/sbin/ndp", arguments: ["-an"], timeout: 3)
        let (arpText, ndpText) = try await (arp, ndp)
        let now = Date()
        var devices = parseARP(arpText, labels: labels, at: now) + parseNDP(ndpText, labels: labels, at: now)
        var hostBuffer = [CChar](repeating: 0, count: 256)
        let status = hostBuffer.withUnsafeMutableBufferPointer { gethostname($0.baseAddress, $0.count) }
        let host = status == 0 ? String(cString: hostBuffer) : "本机"
        for adapter in InterfaceReader.read().adapters where adapter.isUp && adapter.id != "lo0" {
            for ip in adapter.addresses where isIPAddress(ip) {
                let key = BackendValidation.normalizedMAC(adapter.mac)
                let label = key.flatMap { labels[$0] }
                devices.append(DeviceInfo(ip: ip, mac: key ?? adapter.mac, name: label ?? host,
                    hint: "本机macOS自报主机名：\(host)；接口\(adapter.name)；未执行反向名称查询",
                    state: "本机接口已启用", source: "本机接口 / macOS自报", observedAt: now))
            }
        }
        var seen = Set<String>()
        return devices.filter { seen.insert($0.id).inserted }.sorted { $0.ip < $1.ip }
    }

    static func parseARP(_ text: String, labels: [String: String] = [:], at: Date = Date()) -> [DeviceInfo] {
        var result: [DeviceInfo] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let atIndex = fields.firstIndex(of: "at"), atIndex > 0, atIndex + 1 < fields.count else { continue }
            let ip = fields[atIndex - 1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            guard isIPAddress(ip) else { continue }
            let rawMAC = fields[atIndex + 1], mac = BackendValidation.normalizedMAC(rawMAC)
            let interface = fields.firstIndex(of: "on").flatMap { $0 + 1 < fields.count ? fields[$0 + 1] : nil } ?? "未知接口"
            let label = mac.flatMap { labels[$0] }
            result.append(DeviceInfo(ip: ip, mac: mac ?? "", name: label ?? "未知",
                hint: label == nil ? "设备类型未知；缓存不保证当前在线；未扫描或反向查询" : "用户MAC标签；不是远端设备自报",
                state: mac == nil ? "不完整ARP缓存" : "ARP缓存（当前在线性未知）",
                source: "macOS ARP缓存 · " + interface, observedAt: at))
        }
        return result
    }

    static func parseNDP(_ text: String, labels: [String: String] = [:], at: Date = Date()) -> [DeviceInfo] {
        var result: [DeviceInfo] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3, isIPAddress(fields[0]), fields[0].contains(":") else { continue }
            let mac = BackendValidation.normalizedMAC(fields[1]), label = BackendValidation.normalizedMAC(fields[1]).flatMap { labels[$0] }
            result.append(DeviceInfo(ip: fields[0], mac: mac ?? "", name: label ?? "未知",
                hint: label == nil ? "设备类型未知；邻居缓存不保证当前在线；未反向查询" : "用户MAC标签；不是远端设备自报",
                state: fields.count > 4 ? "NDP缓存状态 " + fields[4] : "NDP缓存状态未知",
                source: "macOS NDP缓存 · " + fields[2], observedAt: at))
        }
        return result
    }

    static func importGatewayCSV(url: URL, labels: [String: String] = [:]) throws -> [DeviceInfo] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 10 * 1024 * 1024 else { throw BackendError.invalidInput("网关CSV不能超过10MB") }
        let bytes = try Data(contentsOf: url)
        guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .utf16) else {
            throw BackendError.invalidInput("网关CSV必须使用UTF-8或UTF-16编码")
        }
        let rows = try parseCSV(text)
        guard let header = rows.first else { return [] }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func column(_ aliases: [String]) -> Int? { names.firstIndex { aliases.contains($0) } }
        guard let ipColumn = column(["ip", "address", "ip address", "ipv4", "ipv6", "ip地址", "地址"]) else {
            throw BackendError.invalidInput("CSV需要ip/address/IP地址列；可选mac、name或hostname列")
        }
        let macColumn = column(["mac", "mac address", "macaddress", "mac地址"])
        let nameColumn = column(["name", "hostname", "device", "alias", "名称", "主机名", "设备名"])
        let receivedColumn = column(["download_bps", "download_bytes_per_second"])
        let sentColumn = column(["upload_bps", "upload_bytes_per_second"])
        let observedColumn = column(["observed_at"])
        let typeColumn = column(["device_type", "type"])
        var devices: [DeviceInfo] = []
        for row in rows.dropFirst() {
            guard ipColumn < row.count else { continue }
            let ip = row[ipColumn].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isIPAddress(ip) else { continue }
            let rawMAC = macColumn.flatMap { $0 < row.count ? row[$0] : nil } ?? ""
            let mac = BackendValidation.normalizedMAC(rawMAC)
            let reported = nameColumn.flatMap { $0 < row.count ? row[$0] : nil }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = mac.flatMap { labels[$0] } ?? (reported.isEmpty ? "未知" : String(reported.prefix(120)))
            func value(_ index: Int?) -> String {
                index.flatMap { $0 < row.count ? row[$0].trimmingCharacters(in: .whitespacesAndNewlines) : nil } ?? ""
            }
            let download = importedRate(value(receivedColumn)), upload = importedRate(value(sentColumn))
            let observed = importedDate(value(observedColumn))
            let type = String(value(typeColumn).prefix(120))
            devices.append(DeviceInfo(ip: ip, mac: mac ?? "", name: name,
                hint: "网关CSV声明；" + (type.isEmpty ? "设备类型未知" : "声明类型：" + type + "（未核实）") +
                      "；当前在线性未验证；用量单位B/s",
                state: observed == nil ? "导入记录（采集时间未知，非实时）" : "导入历史记录（不是实时探测）",
                source: "网关CSV导入", downloadBps: download, uploadBps: upload, observedAt: observed))
        }
        var seen = Set<String>(); return devices.filter { seen.insert($0.id).inserted }
    }

    static func importedRate(_ value: String) -> Double? {
        guard let number = Double(value), number.isFinite, number >= 0 else { return nil }
        return number
    }
    static func importedDate(_ value: String) -> Date? {
        guard value.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func parseCSV(_ input: String) throws -> [[String]] {
        let chars = Array(input.first == "\u{feff}" ? String(input.dropFirst()) : input)
        var rows: [[String]] = [], row: [String] = []; var field = ""
        var quoted = false, closedQuote = false; var index = 0
        func emitField() throws {
            guard field.count <= 4096, row.count < 100 else { throw BackendError.invalidInput("CSV单元格或列数过大") }
            row.append(field); field = ""; closedQuote = false
        }
        func emitRow() throws {
            try emitField()
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { rows.append(row) }
            row = []
            guard rows.count <= 10_001 else { throw BackendError.invalidInput("CSV最多导入10000条设备记录") }
        }
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closedQuote = true }
                } else { field.append(char) }
            } else if char == "," { try emitField() }
            else if char == "\n" || char == "\r" || char == "\r\n" {
                try emitRow()
                if char == "\r", index + 1 < chars.count, chars[index + 1] == "\n" { index += 1 }
            } else if char == "\"" {
                guard field.isEmpty, !closedQuote else { throw BackendError.invalidInput("CSV引号格式无效") }
                quoted = true
            } else {
                guard !closedQuote || char.isWhitespace else { throw BackendError.invalidInput("CSV结束引号后出现额外内容") }
                if !closedQuote { field.append(char) }
            }
            guard field.count <= 4096 else { throw BackendError.invalidInput("CSV单元格超过4096字符") }
            index += 1
        }
        guard !quoted else { throw BackendError.invalidInput("CSV存在未闭合的引号") }
        if !field.isEmpty || !row.isEmpty || closedQuote { try emitRow() }
        return rows
    }

    static func isIPAddress(_ text: String) -> Bool {
        let host = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        var v4 = in_addr(); var v6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}

/// Only fixed, read-only system commands are called. No shell, sudo, name lookup,
/// payload capture or subnet scan is used. A timeout terminates our own process.
enum BackendCommand {
    static func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        let operation = PassiveCommand(executable: executable, arguments: arguments, timeout: timeout)
        return try await withTaskCancellationHandler(operation: { try await operation.run() }, onCancel: { operation.cancel() })
    }
}
private final class PassiveCommand: @unchecked Sendable {
    private let process = Process(), pipe = Pipe(), lock = NSLock()
    private let timeout: TimeInterval
    private var promise: CheckedContinuation<String, Error>?
    private var cancelled = false
    private var complete = false
    init(executable: String, arguments: [String], timeout: TimeInterval) {
        self.timeout = timeout; process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    }
    func run() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); promise = continuation; let stop = cancelled; lock.unlock()
            if stop { finish(.failure(CancellationError())); return }
            DispatchQueue.global(qos: .utility).async { [self] in
                do {
                    lock.lock()
                    if complete { lock.unlock(); return }
                    do { try process.run() } catch { lock.unlock(); throw error }
                    lock.unlock()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finish(.failure(BackendError.command("被动邻居缓存读取超时；已停止本次子进程")))
                    }
                    var bytes = Data()
                    while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                        bytes.append(chunk)
                        guard bytes.count <= 2 * 1024 * 1024 else { throw BackendError.command("邻居缓存输出超过2MB上限") }
                    }
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw BackendError.command("系统邻居缓存命令退出码\(process.terminationStatus)") }
                    finish(.success(String(decoding: bytes, as: UTF8.self)))
                } catch { finish(.failure(error)) }
            }
        }
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); finish(.failure(CancellationError())) }
    private func finish(_ value: Result<String, Error>) {
        lock.lock()
        guard !complete, let continuation = promise else { lock.unlock(); return }
        complete = true; promise = nil; let running = process.isRunning; lock.unlock()
        if running { process.terminate() }
        try? pipe.fileHandleForReading.close()
        continuation.resume(with: value)
    }
}

