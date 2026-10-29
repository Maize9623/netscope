import Foundation

/// Every conclusion is limited to this Mac and the requests actually observed.
enum Diagnostics {
    private struct TargetKey: Hashable {
        var id: String; var url: String; var path: String
        init(_ sample: ProbeResult) { id = sample.targetID; url = sample.url; path = sample.pathID }
    }
    private struct ObservationKey: Hashable { var target: TargetKey; var at: Date }
    private struct TrafficKey: Hashable { var adapter: String; var at: Date }

    static func evaluate(frame: MonitorFrame, history: [MonitorFrame]) -> [Finding] {
        var findings: [Finding] = []
        let probes = unique(frame.probes)
        let previous = unique(history.flatMap(\.probes)).filter { $0.at < frame.at }
        func add(_ id: String, _ severity: FindingSeverity, _ title: String, _ evidence: String, _ advice: String, _ confidence: String = "中") {
            findings.append(Finding(id: id, at: frame.at, severity: severity, title: title, evidence: evidence, advice: advice, confidence: confidence))
        }
        let interfaces = frame.local.adapters.filter { $0.id != "lo0" && $0.type.lowercased() != "loopback" }
        if !interfaces.isEmpty && !interfaces.contains(where: \.isUp) {
            add("local:no-active-interface", .critical, "这台 Mac 目前没有连上的网卡", "已读取接口 \(interfaces.count) 个，活动接口 0 个。仅代表本机接口状态。", "先确认 Wi-Fi 已连接或网线已插好，再重新检查。", "高")
        }
        let virtualCount = interfaces.filter { $0.isVirtual && $0.isUp }.count
        if virtualCount > 0 {
            add("local:virtual-interface", .info, "发现正在工作的虚拟网卡", "活动虚拟接口 \(virtualCount) 个。接口开启不代表 VPN 节点健康；物理和虚拟计数可能重复。", "结合下面各应用的连接情况判断 VPN 是否顺畅。", "高")
        }
        if !frame.local.trafficRateReady {
            add("local:warming-up", .info, "还在等待网速样本", "本轮有效网速样本 0 个；首次采样、网卡切换或长时间暂停后需要重新观察。", "保持窗口运行几秒，暂时不要把空白当成网速为零。", "高")
        }
        let missing = probes.filter { isMissing($0) }
        if !missing.isEmpty {
            let skipped = missing.filter { $0.outcome == .skipped }.count
            let invalid = missing.filter { $0.outcome == .invalidURL }.count
            add("probes:missing", .info, "有几项检查还没有完成", "本轮 \(probes.count) 项中缺少有效测量 \(missing.count) 项；跳过 \(skipped) 项，地址无效 \(invalid) 项，采集异常 \(missing.count - skipped - invalid) 项。未计为连接失败。", invalid > 0 ? "检查自定义地址后再试；剩余项目可稍后重测。" : "稍后再检查一次，目前不能据此判断网络或应用出故障。", "高")
        }
        for probe in probes where !isMissing(probe) {
            let key = stableFindingID(probe), title = displayName(probe)
            if let status = httpStatus(probe) {
                let evidence = "本轮 1 次请求收到状态 \(status)；响应耗时 \(duration(probe.httpMs))。只检查了指定地址的一次回应。"
                switch status {
                case 407:
                    add("proxy-auth:" + key, .warning, "上网通道要求先登录", evidence + " 这是代理认证回应，尚未验证目标应用。", "检查公司上网认证或 VPN 的登录状态，再重新检查。", "高")
                case 429:
                    add("rate-limit:" + key, .warning, "\(title)提示请求太频繁", evidence + " 限制可能来自服务、代理或 CDN，不能据此推算账号剩余额度或全站故障。", "稍等一会再试；如果持续出现，查看应用自己的提示和账号额度。", "高")
                case 500...599:
                    add("server-response:" + key, .warning, "\(title)返回了错误", evidence + " 错误可能来自服务、代理或 CDN；单台设备不能证明服务商整体故障。", "先在应用中重试，再用另一条网络交叉检查。", "中")
                case 300...399:
                    add("redirect:" + key, .info, "\(title)让请求转到另一个地址", evidence + " 未继续访问跳转后的地址。", "打开应用确认是否能正常使用；这项检查还不能说明最终页面是否正常。", "高")
                case 401, 403, 404, 405:
                    add("access-response:" + key, .info, "\(title)有回应，实际使用还需确认", evidence + " 登录、访问权限、接口地址或请求方式可能受限制；不是传输中断。", "如果应用本身能用，这条提示可以忽略；如果不能用，查看应用里的登录或权限提示。", "高")
                default: break
                }
                if status != 407, let value = valid(probe.httpMs) {
                    let baseline = previous.filter { TargetKey($0) == TargetKey(probe) && $0.at >= probe.at.addingTimeInterval(-1800) && isPositiveControl($0) }.compactMap { valid($0.httpMs) }
                    if baseline.count >= 5, let typical = percentile(baseline, 0.5), value > 1500, value > typical * 3 {
                        add("slow:" + key, .warning, "\(title)这次明显变慢了", "当前 \(number(value)) ms，过去 30 分钟同配置有效样本 \(baseline.count) 次，中位数 \(number(typical)) ms；门槛为超过中位数 3 倍且超过 1500 ms。", "先观察几轮；如果其他应用也一起变慢，再检查当前网络或 VPN。", "中")
                    }
                }
            } else if isTransportFailure(probe) {
                let repeated = isRepeatedFailure(probe, history: previous)
                add("connect:" + key, repeated ? .warning : .info, repeated ? "\(title)连续两次没连上" : "\(title)这次没连上", "当前 1 次结果 \(probe.outcome.rawValue)；连续失败样本 \(repeated ? 2 : 1) 次，同目标和配置，相邻间隔上限 180 秒。未测量数据包丢失率。", repeated ? "先在应用中重试，再比较其他应用或换一条网络；现在还不能确定是网络、VPN 还是服务的问题。" : "先再检查一次，偶发超时还不能说明是哪一方出了问题。", repeated ? "中" : "低")
            }
        }
        let domestic = probes.filter { $0.group == "国内" || $0.group.lowercased() == "domestic" }
        let external = probes.filter { isExternalGroup($0.group) }
        let domesticResponds = domestic.filter { isPositiveControl($0) }
        let externalFailures = external.filter { isTransportFailure($0) }
        if externalFailures.count >= 2 && !domesticResponds.isEmpty {
            let repeated = externalFailures.filter { isRepeatedFailure($0, history: previous) }.count
            add("correlation:selective-connectivity", repeated >= 2 ? .warning : .info, "有些网站有回应，几个应用却没连上", "国内对照组有效回应 \(domesticResponds.count)/\(domestic.count) 项；其他对照组传输失败 \(externalFailures.count)/\(external.count) 项，其中连续失败 \(repeated) 项。分组不代表实际地理或路由。", "优先检查公司上网通道或 VPN，再用另一条网络比较；也可能是访问限制或个别服务问题，目前不能定责。", "中")
        } else {
            let failed = probes.filter { isTransportFailure($0) }, responding = probes.filter { isPositiveControl($0) }
            if failed.count == 1 && !responding.isEmpty {
                add("correlation:isolated", .info, "目前只有一项连接不顺", "本轮传输失败 1 项，其他有效回应 \(responding.count) 项；未完成 \(missing.count) 项。", "先检查这个应用的提示；它的访问路径、限制或服务本身都有可能，需要重测或换网比较。", "低")
            }
        }
        if probes.isEmpty { add("probes:empty", .info, "还没有服务检查结果", "本轮服务测量样本 0 个。", "开启要关注的项目，然后运行一次检查。", "高") }
        // macOS currently does not send gateway ICMP probes. nil is unknown, never a disconnection.
        return findings
    }

    /// Only the anonymous form is suitable for automatic model input. Raw names, addresses,
    /// collector errors, interface labels, and previous Finding text are deliberately not copied.
    static func buildReport(frames: [MonitorFrame], anonymized: Bool) -> String {
        let ordered = frames.sorted { $0.at < $1.at }, all = unique(frames.flatMap(\.probes))
        var lines = ["测量范围：这台 Mac 的实际样本；不代表全网或服务商整体状态。"]
        guard let first = ordered.first, let last = ordered.last else { return lines.joined(separator: "\n") + "\n实际采样 0 轮，服务样本 0 次；目前没有足够数据判断。" }
        let observedStart = ([first.at] + all.map(\.at) + ordered.map { $0.local.at }).min() ?? first.at
        let observedEnd = ([last.at] + all.map(\.at) + ordered.map { $0.local.at }).max() ?? last.at
        lines.append("时段：\(timestamp(observedStart)) 至 \(timestamp(observedEnd))；实际采样 \(ordered.count) 轮，去重服务样本 \(all.count) 次。暂停、睡眠和漏采样未填零。")
        var keys: [TargetKey] = [], groups: [TargetKey: [ProbeResult]] = [:]
        for sample in all {
            let key = TargetKey(sample)
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(sample)
        }
        for (index, key) in keys.enumerated() {
            guard let samples = groups[key], let latest = samples.last else { continue }
            let attempted = samples.filter { !isMissing($0) }, responses = attempted.filter { httpStatus($0) != nil }
            let failures = attempted.filter { isTransportFailure($0) }, timeouts = attempted.filter { $0.outcome == .timeout && httpStatus($0) == nil }
            let proxyOnly = responses.filter { httpStatus($0) == 407 }.count
            let timings = responses.filter { httpStatus($0) != 407 }.compactMap { valid($0.httpMs) }
            let label = anonymized ? "目标\(index + 1)（\(safeGroup(latest.group))，配置段\(index + 1)）" : "\(displayName(latest)) [\(latest.url)]（独立配置段\(index + 1)）"
            lines.append("\(label)：实际样本 \(samples.count)，尝试 \(attempted.count)，未完成 \(samples.count - attempted.count)；收到回应 \(responses.count)/\(attempted.count)（\(percentage(responses.count, attempted.count))），采样传输失败 \(failures.count)/\(attempted.count)（\(percentage(failures.count, attempted.count))），超时 \(timeouts.count)/\(attempted.count)（\(percentage(timeouts.count, attempted.count))）；P50 \(duration(percentile(timings, 0.5)))，P95 \(duration(percentile(timings, 0.95)))。")
            let codes = Dictionary(grouping: responses, by: { httpStatus($0)! }).map { ($0.key, $0.value.count) }.sorted { $0.0 < $1.0 }.map { "\($0.0):\($0.1)" }.joined(separator: ", ")
            if !codes.isEmpty { lines.append("返回状态计数：\(codes)。") }
            if proxyOnly > 0 { lines.append("其中 \(proxyOnly) 次为 407，仅代理回应，未验证目标，不能作为正常连接的对照。") }
        }
        var seenTraffic = Set<TrafficKey>()
        let locals = ordered.map(\.local).filter { seenTraffic.insert(TrafficKey(adapter: $0.trafficAdapterID, at: $0.at)).inserted }
        let ready = locals.filter(\.trafficRateReady)
        let download = ready.compactMap { valid($0.downloadBps) }, upload = ready.compactMap { valid($0.uploadBps) }
        lines.append("本机流量：有效下载采样 \(download.count) 次，上传采样 \(upload.count) 次；观察到的下载峰值 \(rate(download.max()))，上传峰值 \(rate(upload.max()))。这是所选接口的采样速率，不是线路最大网速或全天连续峰值。")
        if !last.local.trafficRateReady { lines.append("最新网速正在预热或重新建立基线，暂时未知，不能当作零。") }
        let maxGap = zip(ordered, ordered.dropFirst()).map { pair in pair.1.at.timeIntervalSince(pair.0.at) }.max() ?? 0
        if maxGap > 180 { lines.append("相邻采样最大间隔 \(number(maxGap)) 秒；间隔可能含暂停或睡眠，不能据此补记断网。") }
        lines.append("解释边界：收到回应不代表登录或生成内容可用；401/403/404/405不是断网，429为路径上的限制提示，5xx可能来自服务、代理或 CDN。百分比是请求采样结果，不是丢包率。配置段不等于已验证的实际 VPN 出口。网关未做主动探测；未知字段没有填零；邻居记录不能说明别的设备占了多少网速。")
        return anonymized ? boundedReport(lines) : lines.joined(separator: "\n")
    }
    private static func boundedReport(_ lines: [String]) -> String {
        let complete = lines.joined(separator: "\n")
        guard complete.count > 8000, let boundary = lines.last else { return complete }
        var selected: [String] = []
        var used = 0
        for line in lines.dropLast() {
            if used + line.count + boundary.count + 160 > 8000 { break }
            selected.append(line); used += line.count + 1
        }
        selected.append("摘要因长度限制省略了 \(lines.count - selected.count - 1) 行；未包含的目标或配置段仍是未知，不能理解成正常。需要时缩小观察时间或目标范围。")
        selected.append(boundary)
        return selected.joined(separator: "\n")
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sorted.isEmpty, fraction.isFinite else { return nil }
        let index = min(1, max(0, fraction)) * Double(sorted.count - 1)
        let lower = Int(index.rounded(.down)), upper = Int(index.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (index - Double(lower))
    }
    static func httpStatus(_ sample: ProbeResult) -> Int? { guard let code = sample.statusCode, (100...599).contains(code) else { return nil }; return code }
    static func isMissing(_ sample: ProbeResult) -> Bool { httpStatus(sample) == nil && !sample.outcome.isTransportFailure }
    static func isPositiveControl(_ sample: ProbeResult) -> Bool { guard let status = httpStatus(sample) else { return false }; return status != 407 && status < 500 }
    static func isTransportFailure(_ sample: ProbeResult) -> Bool { httpStatus(sample) == nil && sample.outcome.isTransportFailure }
    private static func isRepeatedFailure(_ sample: ProbeResult, history: [ProbeResult]) -> Bool {
        // A newer observation with another path, a missing result, or success breaks the sequence.
        guard let previous = history.filter({ $0.targetID == sample.targetID && $0.url == sample.url && $0.at < sample.at }).max(by: { $0.at < $1.at }), TargetKey(previous) == TargetKey(sample), sample.at.timeIntervalSince(previous.at) <= 180 else { return false }
        return isTransportFailure(previous)
    }
    private static func unique(_ probes: [ProbeResult]) -> [ProbeResult] {
        var seen = Set<ObservationKey>()
        return probes.sorted { $0.at < $1.at }.filter { seen.insert(ObservationKey(target: TargetKey($0), at: $0.at)).inserted }
    }
    private static func valid(_ value: Double?) -> Double? { guard let value, value.isFinite, value >= 0 else { return nil }; return value }
    private static func number(_ value: Double) -> String { String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value) }
    private static func duration(_ value: Double?) -> String { valid(value).map { number($0) + " ms" } ?? "未知" }
    private static func rate(_ value: Double?) -> String { valid(value).map { number($0) + " B/s" } ?? "未知" }
    private static func percentage(_ count: Int, _ total: Int) -> String { total > 0 ? String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), Double(count) * 100 / Double(total)) : "未知" }
    private static func timestamp(_ at: Date) -> String { ISO8601DateFormatter().string(from: at) }
    private static func displayName(_ sample: ProbeResult) -> String { sample.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "这个应用" : sample.name }
    private static func isExternalGroup(_ group: String) -> Bool { ["国际", "AI", "开发", "international", "ai", "development"].contains(group) }
    private static func safeGroup(_ group: String) -> String { ["国内", "国际", "AI", "开发", "状态页"].contains(group) ? group : "自定义组" }
    private static func stableFindingID(_ sample: ProbeResult) -> String {
        // Local-only IDs use lengths so user supplied separators cannot collide.
        [sample.targetID, sample.url, sample.pathID].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}


