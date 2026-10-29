import Foundation

enum BackendError: LocalizedError {
    case invalidInput(String), storage(String), command(String)
    var errorDescription: String? {
        switch self { case .invalidInput(let text), .storage(let text), .command(let text): return text }
    }
}

/// All durable operations are serialized. Settings/labels are replaced atomically
/// with a last-known-valid backup; raw observations are appended as UTF-8 JSONL.
final class LocalStore: @unchecked Sendable {
    let baseURL: URL
    private let historyURL: URL
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var warnings: [String] = []
    var recoveryWarnings: [String] { synchronized { warnings } }

    init(baseURL: URL? = nil) throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.baseURL = (baseURL ?? support.appendingPathComponent("NetScope", isDirectory: true)).standardizedFileURL
        historyURL = self.baseURL.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter(); standard.formatOptions = [.withInternetDateTime]
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, coding in
            var value = coding.singleValueContainer(); try value.encode(fractional.string(from: date))
        }
        decoder.dateDecodingStrategy = .custom { coding in
            let value = try coding.singleValueContainer(); let text = try value.decode(String.self)
            guard let date = fractional.date(from: text) ?? standard.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid UTC ISO8601 timestamp")
            }
            return date
        }
    }

    func loadSettings() throws -> AppSettings {
        try synchronized { try readDocument("settings.json", defaultValue: AppSettings()) }
    }
    func saveSettings(_ settings: AppSettings) throws {
        try synchronized {
            guard (15...3600).contains(settings.intervalSeconds), (3...20).contains(settings.timeoutSeconds),
                  (1...90).contains(settings.retentionDays), (5...1440).contains(settings.aiIntervalMinutes),
                  (0...200).contains(settings.maxAiCallsPerDay), settings.targets.count <= 100 else {
                throw BackendError.invalidInput("设置超出范围：服务间隔15–3600秒、超时3–20秒、保留1–90天、AI每日0–200次、最多100个目标")
            }
            guard Set(settings.targets.map(\.id)).count == settings.targets.count else { throw BackendError.invalidInput("目标ID不能重复") }
            for target in settings.targets where target.enabled {
                guard BackendValidation.targetURL(target.url) != nil else { throw BackendError.invalidInput("目标“\(target.name)”地址无效；请使用不含凭据的HTTP(S)地址") }
            }
            try writeDocument(settings, name: "settings.json")
        }
    }
    func loadDeviceLabels() throws -> [String: String] {
        try synchronized { try readDocument("device-labels.json", defaultValue: [String: String]()) }
    }
    func saveDeviceLabel(mac: String, label: String) throws {
        try synchronized {
            guard let key = BackendValidation.normalizedMAC(mac) else { throw BackendError.invalidInput("需要有效的六字节MAC地址才能保存标签") }
            let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count <= 120 else { throw BackendError.invalidInput("设备标签不能超过120个字符") }
            var labels: [String: String] = try readDocument("device-labels.json", defaultValue: [:])
            if value.isEmpty { labels.removeValue(forKey: key) } else { labels[key] = value }
            try writeDocument(labels, name: "device-labels.json")
        }
    }

    func append(frame: MonitorFrame) throws {
        try synchronized {
            let url = historyURL.appendingPathComponent(Self.dayName(frame.at) + ".jsonl")
            var payload = try encoder.encode(frame); payload.append(0x0a)
            guard payload.count <= 1_048_576 else { throw BackendError.storage("单条原始采样超过1MB，已拒绝写入") }
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw BackendError.storage("无法创建原始历史文件")
                }
            }
            let file = try FileHandle(forUpdating: url); defer { try? file.close() }
            let end = try file.seekToEnd()
            if end > 0 {
                try file.seek(toOffset: end - 1)
                let last = try file.read(upToCount: 1)
                try file.seekToEnd()
                if last?.first != 0x0a {
                    try file.write(contentsOf: Data([0x0a]))
                    warn("\(url.lastPathComponent)：补齐中断记录的行边界；原始内容已保留")
                }
            }
            try file.write(contentsOf: payload); try file.synchronize()
        }
    }

    func loadHistory(since: Date? = nil, limit: Int = 10_000) throws -> [MonitorFrame] {
        try synchronized {
            let maximum = min(100_000, max(1, limit))
            let files = try historyFiles().sorted { $0.lastPathComponent > $1.lastPathComponent }
            let earliestName = since.map(Self.dayName)
            var result: [MonitorFrame] = []
            for file in files {
                if let earliestName = earliestName, file.deletingPathExtension().lastPathComponent < earliestName { continue }
                var recent: [MonitorFrame] = []
                try readLines(file) { data in
                    do {
                        let frame = try decoder.decode(MonitorFrame.self, from: data)
                        if since == nil || frame.at >= since! {
                            recent.append(frame)
                            if recent.count > maximum * 2 { recent.removeFirst(recent.count - maximum) }
                        }
                    } catch { warn("\(file.lastPathComponent)：忽略损坏或未完成的JSONL记录；未删除原文件") }
                }
                result = Array(recent.suffix(maximum)) + result
                if result.count >= maximum { result = Array(result.suffix(maximum)); break }
            }
            return result.sorted { $0.at < $1.at }
        }
    }

    func prune(retentionDays: Int) throws {
        try synchronized {
            let days = min(90, max(1, retentionDays))
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let today = calendar.startOfDay(for: Date())
            let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: today)!
            let oldest = Self.dayName(cutoff)
            for file in try historyFiles() where file.deletingPathExtension().lastPathComponent < oldest {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    private func readDocument<T: Codable>(_ name: String, defaultValue: T) throws -> T {
        let url = baseURL.appendingPathComponent(name), backup = baseURL.appendingPathComponent(name + ".bak")
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists, let data = try? Data(contentsOf: url), let value = try? decoder.decode(T.self, from: data) { return value }
        if let data = try? Data(contentsOf: backup), let value = try? decoder.decode(T.self, from: data) {
            warn("\(name)：主文件不可用，已从上一份有效备份恢复读取")
            return value
        }
        if !exists { return defaultValue }
        throw BackendError.storage("\(name)损坏且没有可用备份；原文件已保留")
    }
    private func writeDocument<T: Codable>(_ value: T, name: String) throws {
        let url = baseURL.appendingPathComponent(name)
        let payload = try encoder.encode(value)
        if let prior = try? Data(contentsOf: url), (try? decoder.decode(T.self, from: prior)) != nil {
            try prior.write(to: baseURL.appendingPathComponent(name + ".bak"), options: .atomic)
        }
        try payload.write(to: url, options: .atomic)
    }
    private func historyFiles() throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(at: historyURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        return files.filter { url in
            guard url.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}\.jsonl$"#, options: .regularExpression) != nil,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }
    private func readLines(_ url: URL, body: (Data) -> Void) throws {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var pending = Data(); var discarding = false
        while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0a) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                if discarding { discarding = false }
                else if !line.isEmpty, line.count <= 1_048_576 { body(line) }
                else if line.count > 1_048_576 { warn("\(url.lastPathComponent)：跳过超大记录") }
            }
            if pending.count > 1_048_576 { pending.removeAll(keepingCapacity: false); discarding = true; warn("\(url.lastPathComponent)：跳过超大或中断记录") }
        }
        if !discarding, !pending.isEmpty { body(pending) }
    }
    private func warn(_ text: String) {
        if warnings.last != text { warnings.append(text) }
        if warnings.count > 50 { warnings.removeFirst(warnings.count - 50) }
    }
    private func synchronized<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    private static func dayName(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}

