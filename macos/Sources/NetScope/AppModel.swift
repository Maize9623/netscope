import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications

struct TrafficChartPoint: Identifiable {
    var id: String
    var at: Date
    var download: Double?
    var upload: Double?
    var segment: String
}
struct LatencyChartPoint: Identifiable {
    var id: String
    var at: Date
    var milliseconds: Double
    var segment: String
}
private struct SavedAIState: Codable {
    var day = ""
    var calls = 0
    var inputTokens: Int? = 0
    var outputTokens: Int? = 0
    var report: AIReport?
    var generatedAt: Date?
    var actualInput = ""
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var settings = AppSettings()
    @Published var local: LocalSample?
    @Published var frame: MonitorFrame?
    @Published var devices: [DeviceInfo] = []
    @Published var events: [Finding] = []
    @Published var trafficPoints: [TrafficChartPoint] = []
    @Published var historyTrafficPoints: [TrafficChartPoint] = []
    @Published var historyLatencyPoints: [LatencyChartPoint] = []
    @Published var historyHours = 24
    @Published var historyTargetID = "traffic"
    @Published var historyBusy = false
    @Published var historyVisible = false
    @Published var processTraffic: ProcessTrafficSnapshot?
    @Published var processBusy = false
    @Published var processAutoEnabled = false
    private var lastProcessAttempt = Date.distantPast
    @Published var isMonitoring = false
    @Published var isChecking = false
    @Published var isAnalyzing = false
    @Published var isRefreshingQuota = false
    @Published var isRefreshingDevices = false
    @Published var status = "准备就绪"
    @Published var settingsMessage = ""
    @Published var errorMessage: String?
    @Published var aiReport: AIReport?
    @Published var lastAIAt: Date?
    @Published var lastAIInput = ""
    @Published var latestPreview = "等待首次完整体检。"
    @Published var aiStatus = "等待首次分析"
    @Published var aiCallsToday = 0
    @Published var aiInputTokensToday: Int? = 0
    @Published var aiOutputTokensToday: Int? = 0
    @Published var quota: QuotaSnapshot?
    @Published var quotaError: String?

    private let monitor = NetworkMonitor()
    private var store: LocalStore?
    private var monitoringTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var started = false
    private var lastCheckAttempt = Date.distantPast
    private var lastQuotaAttempt = Date.distantPast
    private var lastAIAttempt = Date.distantPast
    private var lastPersistedSample = Date.distantPast
    private var liveSamples: [LocalSample] = []
    private var recentFrames: [MonitorFrame] = []
    private var eventTimes: [String: Date] = [:]
    private var usageDay = ""
    private var historyGeneration = 0
    private var deviceLabels: [String: String] = [:]

    init() {
        do {
            let opened = try LocalStore()
            store = opened
            settings = try opened.loadSettings()
            deviceLabels = try opened.loadDeviceLabels()
            restoreAI()
        } catch {
            store = nil
            errorMessage = "无法打开本地数据目录：\(error.localizedDescription)"
        }
    }

    var downloadText: String { local?.trafficRateReady == true ? Self.rate(local?.downloadBps) : "等待采样" }
    var uploadText: String { local?.trafficRateReady == true ? Self.rate(local?.uploadBps) : "等待采样" }
    var issueCount: Int { frame?.findings.filter { $0.severity != .info }.count ?? 0 }
    var infoCount: Int { frame?.findings.filter { $0.severity == .info }.count ?? 0 }
    var medianHTTP: Double? {
        let values = (frame?.probes ?? []).filter { $0.statusCode != nil }.compactMap(\.httpMs).sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        return values.count % 2 == 0 ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }
    var dataDirectory: URL? { store?.baseURL }
    var lowestQuota: QuotaWindow? { quota?.windows.min { $0.remainingPercent < $1.remainingPercent } }
    var enabledTargets: [ProbeTarget] { settings.targets.filter(\.enabled) }
    var lastCheckAt: Date? { frame?.at }

    func start() {
        guard !started else { return }
        started = true
        isMonitoring = settings.autoMonitor

        monitoringTask = Task { [weak self] in
            guard let self else { return }
            await self.loadInitialHistory()
            Task { await self.refreshDevices(); await self.refreshQuota() }
            while !Task.isCancelled {

                await self.tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    func stop() {
        monitoringTask?.cancel()
        checkTask?.cancel()
        monitoringTask = nil
        started = false
    }
    func toggleMonitoring() { isMonitoring.toggle(); status = isMonitoring ? "监测已恢复" : "本地监测已暂停" }
    func toggleAI() { settings.aiAutoEnabled.toggle(); saveSettings(); aiStatus = settings.aiAutoEnabled ? "自动分析已开启" : "自动分析已暂停，本地监测继续" }

    private func tick() async {
        resetUsageDay()
        let now = Date()
        if now.timeIntervalSince(lastQuotaAttempt) >= 600 && !isRefreshingQuota { Task { await refreshQuota() } }
        guard isMonitoring else { return }
        if processAutoEnabled && !processBusy && now.timeIntervalSince(lastProcessAttempt) >= 10 { Task { await refreshProcesses() } }
        let sample = await monitor.captureLocal(selectedAdapterID: settings.trafficAdapterID)
        local = sample
        liveSamples.append(sample)
        liveSamples.removeAll { $0.at < now.addingTimeInterval(-600) }
        trafficPoints = Self.makeTrafficPoints(liveSamples)
        if sample.trafficRateReady && now.timeIntervalSince(lastPersistedSample) >= 30 {
            lastPersistedSample = now
            let saved = MonitorFrame(at: sample.at, local: sample, probes: [])
            recentFrames.append(saved)
            recentFrames.removeAll { $0.at < now.addingTimeInterval(-86400) }
            await persist(saved)
        }
        if now.timeIntervalSince(lastCheckAttempt) >= Double(settings.intervalSeconds) && !isChecking {
            checkTask = Task { [weak self] in await self?.runCheck(manual: false) }
        }
        if settings.aiAutoEnabled && frame != nil && !isAnalyzing && now.timeIntervalSince(lastAIAttempt) >= Double(settings.aiIntervalMinutes * 60) {
            Task { await analyze(manual: false) }
        }
    }

    func runCheck(manual: Bool = true) async {
        guard !isChecking else { return }
        isChecking = true
        lastCheckAttempt = Date()
        status = "正在看电脑联网、常用网站和 AI 应用…"
        defer { isChecking = false }
        var measured = await monitor.snapshot(settings: settings)
        measured.findings = Diagnostics.evaluate(frame: measured, history: recentFrames)
        frame = measured
        if local == nil { local = measured.local }
        recentFrames.append(measured)
        recentFrames.removeAll { $0.at < Date().addingTimeInterval(-86400) }
        await persist(measured)
        eventTimes = eventTimes.filter { $0.value > Date().addingTimeInterval(-3600) }
        var newWarning = false
        for finding in measured.findings {
            let key = finding.title + "|" + finding.evidence
            if let previous = eventTimes[key], finding.at.timeIntervalSince(previous) < 600 { continue }
            eventTimes[key] = finding.at
            events.insert(finding, at: 0)
            if finding.severity != .info {
                newWarning = true
                if settings.notificationsEnabled { notify(finding) }
            }
        }
        if events.count > 1000 { events = Array(events.prefix(1000)) }
        refreshPreview()
        status = "检查完成 · 看了 \(measured.probes.count) 个网站"
        if settings.aiAutoEnabled && (manual || (newWarning && settings.aiOnAnomaly && Date().timeIntervalSince(lastAIAttempt) >= 300)) {
            await analyze(manual: false)
        }
        await refreshHistory()
    }

    private func persist(_ value: MonitorFrame) async {
        guard let storage = store else { return }
        let days = settings.retentionDays
        do { try await Task.detached(priority: .utility) { try storage.append(frame: value); try storage.prune(retentionDays: days) }.value }
        catch { status = "采样继续，但保存失败：\(error.localizedDescription)" }
    }
    private func loadInitialHistory() async {
        guard let storage = store else { return }
        do {
            let loaded = try await Task.detached(priority: .utility) { try storage.loadHistory(since: Date().addingTimeInterval(-86400), limit: 10000) }.value
            recentFrames = loaded
            frame = loaded.last(where: { !$0.probes.isEmpty })
            events = Array(loaded.flatMap(\.findings).sorted { $0.at > $1.at }.prefix(1000))
            refreshPreview()
            await refreshHistory()
        } catch { status = "历史暂不可读：\(error.localizedDescription)" }
    }
    func refreshHistory() async {
        guard let storage = store else { return }
        historyGeneration += 1
        let generation = historyGeneration
        historyBusy = true
        defer { if generation == historyGeneration { historyBusy = false } }
        let since = Date().addingTimeInterval(-Double(historyHours * 3600))
        let targetID = historyTargetID
        let url = settings.targets.first(where: { $0.id == targetID })?.url
        do {
            let frames = try await Task.detached(priority: .utility) { try storage.loadHistory(since: since, limit: 100000) }.value
            guard generation == historyGeneration else { return }
            historyTrafficPoints = Self.makeTrafficPoints(frames.filter { $0.probes.isEmpty }.map(\.local))
            historyTrafficPoints = Self.thin(historyTrafficPoints, maxCount: 1800)
            var latency: [LatencyChartPoint] = []
            var segment = 0
            var previous: ProbeResult?
            for item in frames.sorted(by: { $0.at < $1.at }) {
                guard let probe = item.probes.first(where: { $0.targetID == targetID && $0.url == url }) else { continue }
                if let previous, previous.pathID != probe.pathID || probe.at.timeIntervalSince(previous.at) > Double(settings.intervalSeconds * 3 + 15) { segment += 1 }
                if probe.outcome == .skipped || probe.httpMs == nil || probe.statusCode == nil { segment += 1; previous = probe; continue }
                if let delay = probe.httpMs { latency.append(LatencyChartPoint(id: "\(probe.at.timeIntervalSince1970)-\(probe.targetID)", at: probe.at, milliseconds: delay, segment: "\(segment)")) }
                previous = probe
            }
            historyLatencyPoints = Self.thin(latency, maxCount: 1800)
        } catch { errorMessage = "读取历史失败：\(error.localizedDescription)" }
    }

    func refreshProcesses() async {
        guard !processBusy else { return }
        processBusy = true; lastProcessAttempt = Date()
        defer { processBusy = false }
        do {
            let snapshot = try await ProcessMonitor.capture()
            processTraffic = snapshot
            if let url = store?.baseURL.appendingPathComponent("last-process-traffic.json") {
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            }
        } catch {
            processTraffic = ProcessTrafficSnapshot(at: Date(),intervalSeconds: 0,state: "unknown",note: "这次没有读到软件用量：" + error.localizedDescription,rows: [])
        }
    }
    func refreshDevices() async {
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true
        defer { isRefreshingDevices = false }
        do { devices = try await DeviceCollector.collect(labels: deviceLabels) }
        catch { errorMessage = "读取本机邻居缓存失败：\(error.localizedDescription)" }
    }
    func importGatewayCSV() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try DeviceCollector.importGatewayCSV(url: url, labels: deviceLabels)
            devices.removeAll { $0.source.contains("导入") }
            devices.append(contentsOf: imported)
        } catch { errorMessage = "导入失败：\(error.localizedDescription)" }
    }
    func isDeviceNamed(_ device: DeviceInfo) -> Bool { guard let key = BackendValidation.normalizedMAC(device.mac) else { return false }; return deviceLabels[key] != nil }
    func setDeviceName(mac: String, name: String) {
        guard let storage = store else { return }
        do {
            try storage.saveDeviceLabel(mac: mac, label: name)
            deviceLabels = try storage.loadDeviceLabels()
            Task { await refreshDevices() }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveSettings() {
        settings.intervalSeconds = min(3600, max(15, settings.intervalSeconds))
        settings.timeoutSeconds = min(20, max(3, settings.timeoutSeconds))
        settings.retentionDays = min(90, max(1, settings.retentionDays))
        settings.aiIntervalMinutes = min(1440, max(5, settings.aiIntervalMinutes))
        settings.maxAiCallsPerDay = min(200, max(0, settings.maxAiCallsPerDay))
        guard settings.targets.count <= 64 else { errorMessage = "最多保存64个目标。"; return }
        for target in settings.targets {
            guard let url = URL(string: target.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else {
                errorMessage = "目标「\(target.name)」需要有效的 HTTP / HTTPS URL，且不能含用户名密码。"; return
            }
        }
        do { try store?.saveSettings(settings); settingsMessage = "已保存 · \(Self.time(Date()))" }
        catch { errorMessage = "保存设置失败：\(error.localizedDescription)" }
        if settings.notificationsEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }
    func addTarget() {
        guard settings.targets.count < 64 else { errorMessage = "最多64个目标。"; return }
        settings.targets.append(ProbeTarget(id: UUID().uuidString, name: "新目标", group: "自定义", url: "https://example.com/", enabled: true))
    }
    func removeTarget(id: String) { settings.targets.removeAll { $0.id == id } }

    func refreshPreview() {
        latestPreview = Diagnostics.buildReport(frames: recentFrames, anonymized: true)
        if let capture = processTraffic, Date().timeIntervalSince(capture.at) < 30, !capture.rows.isEmpty {
            latestPreview += "\n本机逐程序短时间用量：\(capture.intervalSeconds)秒，状态\(capture.state)。只统计系统提供的记录，VPN可能重复，不代表带宽占满或异常软件。\n"
            for (index, row) in capture.rows.prefix(8).enumerated() {
                latestPreview += String(format: "程序%d：下载 %.0f B/s，上传 %.0f B/s，所显示记录占比 %.1f%%\n",index+1,row.downloadBps,row.uploadBps,row.observedSharePercent)
            }
        }
    }
    func analyze(manual: Bool = true) async {
        guard !isAnalyzing else { return }
        resetUsageDay()
        guard frame != nil else { errorMessage = "请先完成一次体检。"; return }
        guard manual || settings.aiAutoEnabled else { return }
        guard aiCallsToday < settings.maxAiCallsPerDay else { aiStatus = "已到今日调用上限，本地监测继续"; return }
        isAnalyzing = true
        lastAIAttempt = Date()
        refreshPreview()
        let input = latestPreview
        aiCallsToday += 1
        aiStatus = "正在发送匿名摘要并等待分析…"
        saveAIState()
        defer { isAnalyzing = false }
        do {
            let result = try await AIClient.analyze(summary: input, codexPath: settings.codexPath.isEmpty ? nil : settings.codexPath)
            aiReport = result.report
            lastAIAt = result.generatedAt
            lastAIInput = input
            aiInputTokensToday = Self.addTokens(aiInputTokensToday, result.inputTokens)
            aiOutputTokensToday = Self.addTokens(aiOutputTokensToday, result.outputTokens)
            aiStatus = "分析完成 · \(Self.time(result.generatedAt))"
            saveAIState()
        } catch {
            aiInputTokensToday = nil; aiOutputTokensToday = nil
            aiStatus = "分析未完成：\(error.localizedDescription)"
            saveAIState()
        }
    }
    func refreshQuota() async {
        guard !isRefreshingQuota else { return }
        isRefreshingQuota = true; lastQuotaAttempt = Date(); quotaError = nil
        defer { isRefreshingQuota = false }
        do { quota = try await QuotaClient.fetch(codexPath: settings.codexPath.isEmpty ? nil : settings.codexPath) }
        catch { quotaError = error.localizedDescription }
    }

    func exportReport() {
        var report = Diagnostics.buildReport(frames: recentFrames, anonymized: false)
        if let aiReport {
            report += "\n\n── 最近 AI 结论 ──\n分析时间：\(lastAIAt.map(Self.time) ?? "未知")\n\(aiReport.summary)\n\(aiReport.details)\n\n── 此次实际匿名输入 ──\n\(lastAIInput)"
        }
        saveText(report, proposedName: "NetScope-report.txt")
    }
    func exportHistory() {
        guard let storage = store else { errorMessage = "没有可用的记录目录"; return }
        let since = Date().addingTimeInterval(-Double(historyHours * 3600))
        Task {
            do {
                let frames = try await Task.detached(priority: .utility) { try storage.loadHistory(since: since, limit: 1_000_000) }.value
                let formatter = ISO8601DateFormatter()
                let rows = frames.filter { $0.probes.isEmpty }.map { frame -> String in
                    let local = frame.local
                    return formatter.string(from: frame.at) + "," + (local.downloadBps.map { String($0) } ?? "") + "," + (local.uploadBps.map { String($0) } ?? "")
                }
                saveText("observed_at,download_bytes_per_second,upload_bytes_per_second\n" + rows.joined(separator: "\n"), proposedName: "NetScope-history.csv")
            } catch { errorMessage = "导出失败：" + error.localizedDescription }
        }
    }
    private func saveText(_ text: String, proposedName: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = proposedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = "导出失败：\(error.localizedDescription)" }
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }

    private func notify(_ finding: Finding) {
        let content = UNMutableNotificationContent(); content.title = "NetScope · \(finding.title)"; content.body = finding.advice
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    private static func addTokens(_ total: Int?, _ next: Int?) -> Int? { guard let total, let next else { return nil }; return total + next }
    private func resetUsageDay() {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; let today = formatter.string(from: Date())
        guard usageDay != today else { return }
        usageDay = today; aiCallsToday = 0; aiInputTokensToday = 0; aiOutputTokensToday = 0; saveAIState()
    }
    private func restoreAI() {
        guard let url = store?.baseURL.appendingPathComponent("ai-state.json"), let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(SavedAIState.self, from: data) else { return }
        usageDay = saved.day; aiCallsToday = saved.calls; aiInputTokensToday = saved.inputTokens; aiOutputTokensToday = saved.outputTokens
        aiReport = saved.report; lastAIAt = saved.generatedAt; lastAIInput = saved.actualInput
        resetUsageDay()
        if lastAIAt != nil { aiStatus = "已载入最近分析；请结合新的测量复核" }
    }
    private func saveAIState() {
        guard let url = store?.baseURL.appendingPathComponent("ai-state.json") else { return }
        let saved = SavedAIState(day: usageDay, calls: aiCallsToday, inputTokens: aiInputTokensToday, outputTokens: aiOutputTokensToday, report: aiReport, generatedAt: lastAIAt, actualInput: lastAIInput)
        do { try JSONEncoder().encode(saved).write(to: url, options: .atomic) }
        catch { aiStatus = "AI 用量记录保存失败：\(error.localizedDescription)" }
    }
    private static func makeTrafficPoints(_ values: [LocalSample]) -> [TrafficChartPoint] {
        var result: [TrafficChartPoint] = []; var segment = 0; var previous: LocalSample?
        for value in values.sorted(by: { $0.at < $1.at }) {
            if let previous, value.trafficAdapterID != previous.trafficAdapterID || value.proxySummary != previous.proxySummary || value.at.timeIntervalSince(previous.at) > 100 { segment += 1 }
            if !value.trafficRateReady { segment += 1; previous = value; continue }
            result.append(TrafficChartPoint(id: "\(value.at.timeIntervalSince1970)-\(value.trafficAdapterID)", at: value.at, download: value.downloadBps, upload: value.uploadBps, segment: "\(segment)"))
            previous = value
        }
        return result
    }
    private static func thin<T>(_ values: [T], maxCount: Int) -> [T] {
        guard values.count > maxCount else { return values }
        let stride = Double(values.count - 1) / Double(maxCount - 1)
        return (0..<maxCount).map { values[Int((Double($0) * stride).rounded())] }
    }
    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "暂时不知道" }
        if value >= 1_048_576 { return String(format: "%.2f MiB/s", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.1f KiB/s", value / 1024) }
        return String(format: "%.0f B/s", value)
    }
    static func delay(_ value: Double?) -> String { value.map { String(format: "%.1f ms", $0) } ?? "暂时不知道" }
    static func time(_ value: Date) -> String { value.formatted(.dateTime.year().month().day().hour().minute().second()) }
}
