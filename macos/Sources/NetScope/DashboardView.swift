import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("netscope.theme") private var theme = "system"
    @AppStorage("netscope.details") private var details = false
    @State private var page = "检查为什么卡"
    private let pages = ["检查为什么卡","现在上网怎么样","过去的变化","这是什么设备","哪个软件在用网","AI 帮我看","额度与开关","本机网络","卡顿记录","我的设置"]
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                Text("NETSCOPE").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("上网助手").foregroundStyle(.mint)
                List(pages, id: \.self, selection: Binding<String?>(get: { page }, set: { if let value = $0 { page = value } })) { name in Label(name, systemImage: Self.pageSymbol(name)).tag(name).padding(.vertical, 5) }.listStyle(.sidebar)
                Text("记录留在这台电脑\n关掉窗口后仍可后台检查").font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 24).padding(.horizontal, 12).frame(minWidth: 215)
        } detail: {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch page {
                        case "检查为什么卡": checkPage
                        case "现在上网怎么样": overviewPage
                        case "过去的变化": historyPage
                        case "这是什么设备": DevicesPage(details: details)
                        case "哪个软件在用网": ProcessPage(details: details)
                        case "AI 帮我看": AIPage(details: details)
                        case "额度与开关": QuotaPage()
                        case "本机网络": adaptersPage
                        case "卡顿记录": eventsPage
                        default: SettingsPage()
                        }
                    }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .preferredColorScheme(theme == "dark" ? .dark : theme == "light" ? .light : nil)
        .onChange(of: page) { _, value in
            model.historyVisible = value == "过去的变化"
            if model.historyVisible { Task { await model.refreshHistory() } }
        }
        .alert("NetScope", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text(page).font(.largeTitle.bold()); Text(model.status).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Picker("外观", selection: $theme) { Text("跟随系统").tag("system"); Text("日间").tag("light"); Text("夜间").tag("dark") }.frame(width: 140)
            }
            HStack {
                if page != "检查为什么卡" {
                    Button("检查现在为什么卡") { page = "检查为什么卡"; Task { await model.runCheck() } }.buttonStyle(.borderedProminent).tint(.teal).disabled(model.isChecking)
                    if model.isChecking { ProgressView().controlSize(.small) }
                }
                Button(model.isMonitoring ? "暂停后台" : "恢复后台") { model.toggleMonitoring() }
                Button("小悬浮窗") { MiniPanelController.shared.toggle(model: model) }
                Spacer()
                Toggle("详细模式", isOn: $details).toggleStyle(.switch).controlSize(.small)
            }
        }.padding(24).background(.regularMaterial)
    }
    private var probes: [ProbeResult] { model.frame?.probes ?? [] }
    private var failed: [ProbeResult] { probes.filter { Diagnostics.isTransportFailure($0) } }
    private var responses: Int { probes.filter { Diagnostics.httpStatus($0) != nil && $0.statusCode != 407 }.count }
    private var overview: CheckOverview {
        CheckOverview.make(probes: probes, checking: model.isChecking, hasFrame: model.frame != nil, issueCount: model.issueCount)
    }
    private var activeProcess: ProcessTrafficRow? {
        guard let sample = model.processTraffic, ["measured", "partial"].contains(sample.state) else { return nil }
        return sample.rows.filter { $0.downloadBps.isFinite && $0.uploadBps.isFinite && $0.downloadBps + $0.uploadBps > 0 }.max { $0.downloadBps + $0.uploadBps < $1.downloadBps + $1.uploadBps }
    }
    private var checkPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center, spacing: 30) {
                ZStack {
                    Circle().fill(overview.tint.opacity(0.09)).frame(width: 132, height: 132)
                    Circle().stroke(overview.tint.opacity(0.20), lineWidth: 1).frame(width: 132, height: 132)
                    if model.isChecking { ProgressView().controlSize(.large).tint(.teal).scaleEffect(1.4) }
                    else { Image(systemName: overview.symbol).font(.system(size: 52, weight: .light)).foregroundStyle(overview.tint).symbolRenderingMode(.hierarchical) }
                }.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text(overview.title).font(.system(size: 28, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(overview.note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button { Task { await model.runCheck() } } label: {
                        Label(model.isChecking ? "正在检查…" : "立即检查", systemImage: "waveform.path.ecg")
                            .font(.headline).padding(.horizontal, 22).padding(.vertical, 5)
                    }.buttonStyle(.borderedProminent).controlSize(.large).tint(.teal).disabled(model.isChecking)
                    Text(model.isChecking ? "正在收集新结果，下方保留上一次已完成的检查。" : model.lastCheckAt.map { "最近完成于 " + AppModel.time($0) } ?? "按你启用的项目检查，结果保存在这台 Mac。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                .background(overview.tint.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))

            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("这次检查告诉你什么").font(.title3.weight(.semibold)); Spacer(); Text("点开一项看说明").font(.caption).foregroundStyle(.secondary) }
                VStack(spacing: 0) {
                    CheckResultRow(symbol: "network", title: "现在网络怎么了？", conclusion: overview.resultLine,
                        note: "每个应用都单独检查。有回应只说明这次连接收到了回复，登录、聊天和生成内容仍要在应用中确认。", tint: overview.tint)
                    Divider().padding(.leading, 42)
                    CheckResultRow(symbol: "point.3.connected.trianglepath.dotted", title: "哪里可能不通？",
                        conclusion: probes.isEmpty ? "还没有足够结果" : !failed.isEmpty || model.issueCount > 0 ? "需要结合多次结果判断" : probes.contains(where: { Diagnostics.isMissing($0) }) ? "有项目还没测到" : "这次没有发现连接失败",
                        note: "本机、当前网络、VPN 和应用服务都可能影响体验。一次检查无法确定责任；持续记录与换网对比能帮助缩小范围。")
                    Divider().padding(.leading, 42)
                    CheckResultRow(symbol: "arrow.down.up", title: "网速正常吗？", conclusion: "当前下载 " + model.downloadText,
                        note: "这是所选接口正在使用的速率，不是宽带上限。上传为 \(model.uploadText)。Mac 版目前没有主动测速，不能据此判断最大带宽是否正常。", action: "看看用量曲线") { page = "现在上网怎么样" }
                    Divider().padding(.leading, 42)
                    CheckResultRow(symbol: "desktopcomputer.and.macbook", title: "别的设备在占网吗？",
                        conclusion: model.devices.contains(where: { $0.source == "网关CSV导入" && ($0.downloadBps != nil || $0.uploadBps != nil) }) ? "有导入记录，需核对记录时间" : "目前还不知道",
                        note: "设备缓存只能说明这台 Mac 曾经看到过某些记录。判断其他设备用了多少网，需要路由器提供对应时段的用量。", action: "打开网络设备工位") { page = "这是什么设备" }
                    Divider().padding(.leading, 42)
                    CheckResultRow(symbol: "app.connected.to.app.below.fill", title: "哪个软件在用网？",
                        conclusion: activeProcess.map { ProcessPage.friendly($0) + " 在上次记录中用得较多" } ?? "可以单独观察本机软件",
                        note: "这里比较系统返回的短时间记录；VPN 和应用可能重复记账，不能把它们相加当作整条线路的用量。", action: "打开软件工位") { page = "哪个软件在用网" }
                    Divider().padding(.leading, 42)
                    CheckResultRow(symbol: "lightbulb", title: "接下来怎么做？", conclusion: probes.isEmpty ? "先完成一次检查" : failed.isEmpty ? "在刚才卡顿的应用里再试一下" : "重试，并比较另一条网络",
                        note: "如果仍然卡顿，AI 可以结合实际记录解释哪些原因值得怀疑。信息不足时会保留“不知道”，调用会消耗模型额度。", action: "查看 AI 分析") { page = "AI 帮我看" }
                }.padding(.horizontal, 18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            }
            DisclosureGroup("查看每个应用的检查详情") { services.padding(.top, 14) }
                .font(.headline)
        }
    }
    private static func pageSymbol(_ name: String) -> String {
        switch name {
        case "检查为什么卡": return "waveform.path.ecg"
        case "现在上网怎么样": return "network"
        case "过去的变化": return "chart.xyaxis.line"
        case "这是什么设备": return "desktopcomputer.and.macbook"
        case "哪个软件在用网": return "app.connected.to.app.below.fill"
        case "AI 帮我看": return "sparkles"
        case "额度与开关": return "slider.horizontal.3"
        case "本机网络": return "point.3.connected.trianglepath.dotted"
        case "卡顿记录": return "clock"
        default: return "gearshape"
        }
    }
    private var overviewPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { MetricTile(title: "正在下载", value: model.downloadText); MetricTile(title: "正在上传", value: model.uploadText); MetricTile(title: "这次没回应", value: probes.isEmpty ? "尚未检查" : "\(failed.count) 个") }
            Text("最近十分钟 · 这台电脑正在用多少网").font(.headline)
            TrafficGraph(points: model.trafficPoints).frame(height: 250)
            Text("空白表示没有测到；没有把睡眠或暂停时段当作断网。").font(.callout).foregroundStyle(.secondary)
            services
        }
    }
    private var services: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("哪些应用有回应？").font(.title2.bold())
            if probes.isEmpty { Text("检查完成后，这里会出现逐个结果。").foregroundStyle(.secondary) }
            ForEach(probes) { result in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: result.outcome.isTransportFailure ? "exclamationmark.circle.fill" : "network").foregroundStyle(result.outcome.isTransportFailure ? Color.orange : Color.teal)
                        Text(result.name.replacingOccurrences(of: " API", with: "")).font(.headline)
                        Spacer()
                        Text(Self.friendly(result)).foregroundStyle(.secondary)
                    }
                    if details { Text("\(result.url)\nHTTP \(result.statusCode.map(String.init) ?? "未知") · 等待 \(AppModel.delay(result.httpMs))\n\(result.route)\n\(result.error)").font(.caption.monospaced()).textSelection(.enabled) }
                }.padding(16).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    static func friendly(_ result: ProbeResult) -> String {
        switch result.outcome {
        case .ok: return "有回应，还没验证全部功能"
        case .authRequired,.forbidden,.notFound,.methodNotAllowed: return "有回应，尚未测试能否正常使用"
        case .redirect: return "有回应，要求打开另一个页面"
        case .proxyAuthRequired: return "上网通道要求先登录"
        case .rateLimited: return "要求少发一些请求"
        case .serverError,.httpError: return "有回应，但发回错误提示"
        case .timeout: return "这次等了太久，没回应"
        case .skipped,.error: return "这次没测到，不能判断"
        case .invalidURL: return "检测设置需要修改"
        default: return "这次没有连接成功"
        }
    }
    private var historyPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Picker("看多久", selection: $model.historyHours) { Text("1 小时").tag(1); Text("一天").tag(24); Text("一周").tag(168); Text("30 天").tag(720) }.frame(width: 190)
                Picker("看什么", selection: $model.historyTargetID) { Text("本机用量").tag("traffic"); ForEach(model.settings.targets) { Text($0.name).tag($0.id) } }.frame(width: 220)
                Button("刷新") { Task { await model.refreshHistory() } }; Button("导出数字") { model.exportHistory() }
                if model.historyBusy { ProgressView().controlSize(.small) }
            }.onChange(of: model.historyHours) { _, _ in Task { await model.refreshHistory() } }.onChange(of: model.historyTargetID) { _, _ in Task { await model.refreshHistory() } }
            if model.historyTargetID == "traffic" { TrafficGraph(points: model.historyTrafficPoints).frame(height: 360) }
            else { Chart(model.historyLatencyPoints) { point in LineMark(x: .value("时间",point.at),y: .value("等待毫秒",point.milliseconds),series: .value("连续记录",point.segment)).foregroundStyle(.teal) }.frame(height: 360) }
            Text("空白是缺少记录，不代表网络坏了。切换网络后会分段展示。历史用量是实际保存的抽样，不代表每一秒的峰值。").foregroundStyle(.secondary)
        }
    }
    private var adaptersPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("电脑有哪些联网方式？").font(.title2.bold())
            ForEach(model.local?.adapters ?? []) { adapter in
                VStack(alignment: .leading, spacing: 8) {
                    Label(adapter.name,systemImage: adapter.isVirtual ? "network.badge.shield.half.filled" : "desktopcomputer").font(.headline)
                    Text(adapter.isUp ? "系统显示已连接" : "系统显示未连接")
                    Text(adapter.isVirtual ? "可能是 VPN 或系统建立的连接" : "可能是实际联网设备").foregroundStyle(.secondary)
                    Text("↓ \(AppModel.rate(adapter.downloadBps))    ↑ \(AppModel.rate(adapter.uploadBps))")
                    if details { Text("\(adapter.description)\n地址：\(adapter.addresses.joined(separator: ", "))\n网关：\(adapter.gateways.joined(separator: ", "))\nDNS：\(adapter.dnsServers.joined(separator: ", "))\nMAC：\(adapter.mac)").font(.caption.monospaced()).textSelection(.enabled) }
                }.padding(18).frame(maxWidth: .infinity,alignment: .leading).background(Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
            }
            if details { Text(model.local?.proxySummary ?? "尚未读取").textSelection(.enabled) }
        }
    }
    private var eventsPage: some View {
        VStack(alignment: .leading,spacing:14) {
            Text("自动记下值得留意的变化").font(.title2.bold())
            if model.events.isEmpty { Text("目前没有保存的提醒，继续挂机即可积累记录。").foregroundStyle(.secondary) }
            ForEach(model.events.prefix(300)) { event in
                VStack(alignment:.leading,spacing:8) {
                    HStack { Text(event.title).font(.headline); Spacer(); Text(AppModel.time(event.at)).font(.caption).foregroundStyle(.secondary) }
                    Text(event.advice)
                    if details { Text(event.evidence).font(.caption.monospaced()).textSelection(.enabled) }
                }.padding(16).background(Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
            }
        }
    }
}

/// Presentation uses measured outcomes, never a synthetic health score.
struct CheckOverview {
    var title: String
    var note: String
    var resultLine: String
    var symbol: String
    var attention: Bool
    var tint: Color { attention ? .orange : .teal }
    static func make(probes: [ProbeResult], checking: Bool, hasFrame: Bool, issueCount: Int) -> CheckOverview {
        let failures = probes.filter { Diagnostics.isTransportFailure($0) }.count
        let missing = probes.filter { Diagnostics.isMissing($0) }.count
        let replies = probes.filter { Diagnostics.httpStatus($0) != nil && $0.statusCode != 407 }.count
        let authentication = probes.filter { $0.statusCode == 407 }.count
        let notices = probes.filter { probe in guard let code = Diagnostics.httpStatus(probe) else { return false }; return code == 429 || code >= 500 }.count
        let result: String
        if probes.isEmpty { result = "还没有服务检查结果" }
        else if failures > 0 { result = "\(failures) 项没连上，\(replies) 项有回应" }
        else if authentication > 0 { result = "上网通道要求先登录" }
        else if missing > 0 { result = "\(replies) 项有回应，\(missing) 项还没测到" }
        else { result = "这次 \(replies) 个应用有回应" }
        if checking { return CheckOverview(title: "正在检查当前连接", note: "正在查看这台 Mac、常用网站和你选择的 AI 应用。", resultLine: result, symbol: "waveform.path.ecg", attention: false) }
        if !hasFrame { return CheckOverview(title: "现在上网顺不顺？", note: "做一次检查，再根据实际结果告诉你哪里值得留意。", resultLine: result, symbol: "network", attention: false) }
        if probes.isEmpty { return CheckOverview(title: "还需要一些检查结果", note: "当前没有服务样本。可以在设置里开启你关注的应用，再检查一次。", resultLine: result, symbol: "questionmark.circle", attention: false) }
        if failures > 0 { return CheckOverview(title: "有 \(failures) 项连接值得检查", note: "这次没有连上，还不能确定是当前网络、VPN 还是应用服务的问题。", resultLine: result, symbol: "wifi.exclamationmark", attention: true) }
        if authentication > 0 { return CheckOverview(title: "上网通道需要先登录", note: "目前还没验证这些应用是否正常。先查看公司上网认证或 VPN 的提示。", resultLine: result, symbol: "person.crop.circle.badge.exclamationmark", attention: true) }
        if notices > 0 || issueCount > 0 { return CheckOverview(title: "有回应，也有值得留意的提示", note: "展开下面的结果，看看哪些应用返回错误或出现了明显变化。", resultLine: result, symbol: "exclamationmark.bubble", attention: true) }
        if missing > 0 { return CheckOverview(title: "有 \(missing) 项还没有测到", note: "没有完成的检查暂时不能判断，稍后再试一次。", resultLine: result, symbol: "questionmark.circle", attention: false) }
        return CheckOverview(title: "这次 \(replies) 个应用有回应", note: "连接收到了回复；登录和聊天是否正常，还需要在应用里确认。", resultLine: result, symbol: "network", attention: false)
    }
}

struct CheckResultRow: View {
    var symbol: String; var title: String; var conclusion: String; var note: String
    var tint: Color = .teal; var action: String? = nil; var perform: (() -> Void)? = nil
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let action { Button(action) { perform?() }.font(.callout) }
            }.padding(.leading, 36).padding(.bottom, 14).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(tint).frame(width: 24)
                Text(title).font(.body.weight(.medium)).frame(width: 180, alignment: .leading)
                Text(conclusion).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }.padding(.vertical, 18)
        }.tint(.secondary)
    }
}
struct QuestionCard: View {
    var title: String; var conclusion: String; var note: String; var action: String? = nil; var perform: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(conclusion).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
            Text(note).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action { Button(action) { perform?() }.frame(maxWidth: .infinity) }
        }.padding(22).frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}
struct MetricTile: View {
    var title:String;var value:String
    var body:some View { VStack(alignment:.leading,spacing:10) {Text(title).foregroundStyle(.secondary);Text(value).font(.title2.bold()).monospacedDigit()}.padding(22).frame(maxWidth:.infinity,alignment:.leading).background(Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:14)) }
}
struct TrafficGraph: View {
    var points: [TrafficChartPoint]
    var body: some View {
        Chart(points) { point in
            if let down=point.download {LineMark(x:.value("时间",point.at),y:.value("KiB/s",down/1024),series:.value("记录",point.segment+"down")).foregroundStyle(.teal)}
            if let up=point.upload {LineMark(x:.value("时间",point.at),y:.value("KiB/s",up/1024),series:.value("记录",point.segment+"up")).foregroundStyle(.blue)}
        }.chartYAxisLabel("下载（绿）/ 上传（蓝） · KiB/s")
    }
}
