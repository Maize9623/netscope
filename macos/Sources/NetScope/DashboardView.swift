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
                List(pages, id: \.self, selection: Binding<String?>(get: { page }, set: { if let value = $0 { page = value } })) { name in Text(name).tag(name).padding(.vertical, 5) }.listStyle(.sidebar)
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
                Button("检查现在为什么卡") { page = "检查为什么卡"; Task { await model.runCheck() } }.buttonStyle(.borderedProminent).tint(.teal).disabled(model.isChecking)
                if model.isChecking { ProgressView().controlSize(.small) }
                Button(model.isMonitoring ? "暂停后台" : "恢复后台") { model.toggleMonitoring() }
                Button("小悬浮窗") { MiniPanelController.shared.toggle(model: model) }
                Spacer()
                Toggle("详细模式", isOn: $details).toggleStyle(.switch).controlSize(.small)
            }
        }.padding(24).background(.regularMaterial)
    }
    private var probes: [ProbeResult] { model.frame?.probes ?? [] }
    private var failed: [ProbeResult] { probes.filter { $0.outcome.isTransportFailure } }
    private var responses: Int { probes.filter { $0.statusCode != nil && $0.statusCode != 407 }.count }
    private var checkPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.isChecking ? "正在检查：电脑联网 → 常用网站 → AI 应用" : model.lastCheckAt.map { "最近检查：" + AppModel.time($0) } ?? "点上方按钮，看看现在为什么卡。")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), alignment: .top)], spacing: 16) {
                QuestionCard(title: "1 · 现在网络怎么了？", conclusion: probes.isEmpty ? "还没开始检查" : failed.isEmpty ? "这次有 \(responses) 个网站回应" : "\(failed.count) 个应用这次没回应", note: "有回应不等于已经验证能正常聊天。下面逐个列出结果。")
                QuestionCard(title: "2 · 哪里可能不通？", conclusion: probes.isEmpty ? "还没有结果" : failed.isEmpty ? "暂时没发现连不上的地方" : "目前还不能确定", note: failed.isEmpty ? "如果你仍然觉得卡，需要继续记录卡顿发生的那一刻。" : "可能与本机、公司网络、VPN 或应用服务有关，不能只凭一次检查认定是谁的问题。")
                QuestionCard(title: "3 · 网速正常吗？", conclusion: "还没测最大下载速度", note: "当前下载 \(model.downloadText)。这是正在用的量，不能当作你的宽带上限。Mac 版暂未提供主动测速。")
                QuestionCard(title: "4 · 别的设备在占网吗？", conclusion: model.devices.contains(where: { $0.downloadBps != nil }) ? "有路由器提供的用量记录" : "现在还查不到", note: "需要路由器提供各设备的用量。只看到设备出现，不能判断它抢了多少网。", action: "看看有哪些设备") { page = "这是什么设备" }
                QuestionCard(title: "5 · 我的哪个软件在用网？", conclusion: model.processTraffic?.rows.first.map { ProcessPage.friendly($0) + " 在上次记录中用得较多" } ?? "可以检查本机软件", note: "读取系统提供的短时间用量，不限制任何软件。VPN 和应用的记录可能重复。", action: "查看软件工位") { page = "哪个软件在用网" }
                QuestionCard(title: "6 · 我应该怎么做？", conclusion: failed.isEmpty ? "先试试刚才觉得卡的应用" : "先重试，再比较另一网络", note: "若持续卡顿，让 AI 结合这段时间的记录给建议；它判断不了时会直接说不知道。", action: "让 AI 帮我看") { page = "AI 帮我看" }
            }
            services
        }
    }
    private var overviewPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { MetricTile(title: "正在下载", value: model.downloadText); MetricTile(title: "正在上传", value: model.uploadText); MetricTile(title: "这次没回应", value: "\(failed.count) 个") }
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
