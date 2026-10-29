import SwiftUI
import AppKit

struct DevicesPage: View {
    @EnvironmentObject private var model: AppModel
    var details: Bool
    @State private var selected: DeviceInfo?
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading,spacing:18) {
            HStack {Text("网络设备工位").font(.title2.bold());Spacer();Button("刷新") {Task {await model.refreshDevices()}}.disabled(model.isRefreshingDevices);Button("导入路由器的用量记录") {model.importGatewayCSV()} }
            Text("这里是电脑当前知道的设备，不一定包含全网。名字和类型有时只能推测；你可以点卡片给它起名。").foregroundStyle(.secondary)
            if model.devices.isEmpty {Text("暂时没有设备记录。先正常使用网络，再点刷新。").padding(30)}
            LazyVGrid(columns:[GridItem(.adaptive(minimum:260),alignment:.top)],spacing:16) {
                ForEach(model.devices) {device in
                    VStack(alignment:.leading,spacing:12) {
                        HStack {Image(systemName: Self.symbol(device)).font(.system(size:30)).foregroundStyle(.teal);Spacer();Text(device.source.contains("本机") ? "这台电脑" : model.isDeviceNamed(device) ? "你已命名" : "名字待你确认").font(.caption).foregroundStyle(.secondary)}
                        Text(device.name == "未知" || device.name.isEmpty ? "未知设备" : device.name).font(.title3.bold()).lineLimit(2)
                        Text(Self.guess(device)).foregroundStyle(.secondary)
                        if device.downloadBps != nil || device.uploadBps != nil {
                            Text("↓ \(AppModel.rate(device.downloadBps))  ↑ \(AppModel.rate(device.uploadBps))").monospacedDigit()
                            Text("记录时间："+(device.observedAt.map(AppModel.time) ?? "未知，不能当实时用量")).font(.caption).foregroundStyle(.secondary)
                        } else {Text("用了多少网：还查不到").font(.callout);Text("需要路由器提供记录。").font(.caption).foregroundStyle(.secondary)}
                        Button("给它起名字") {name = device.name == "未知" ? "" : device.name;selected=device}.disabled(BackendValidation.normalizedMAC(device.mac) == nil)
                        if details {Text("\(device.ip)\n\(device.mac)\n\(device.source)\n\(device.state)\n\(device.hint)").font(.caption.monospaced()).textSelection(.enabled)}
                    }.padding(20).frame(maxWidth:.infinity,minHeight:240,alignment:.topLeading).background(Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:16))
                }
            }
        }.sheet(item:$selected) {device in
            VStack(alignment:.leading,spacing:20) {
                Text("记住这台设备").font(.title2.bold())
                TextField("比如：我的 Mac mini / 会议室电视",text:$name)
                Text("这个名字保存在本机。设备换了网络身份后，可能需要重新确认。").font(.callout).foregroundStyle(.secondary)
                HStack {Button("取消") {selected=nil};Spacer();Button("保存") {model.setDeviceName(mac:device.mac,name:name);selected=nil}.buttonStyle(.borderedProminent)}
            }.padding(28).frame(width:460)
        }
    }
    static func guess(_ device:DeviceInfo)->String {
        if device.source.contains("本机") {return "这台 Mac 的本机记录"}
        let text=(device.name+" "+device.hint).lowercased()
        if ["iphone","android","手机","redmi"].contains(where:text.contains) {return "可能是手机 · 根据已有名字推测"}
        if ["ipad","平板"].contains(where:text.contains) {return "可能是平板 · 根据已有名字推测"}
        if ["macbook","mac mini","macmini","imac","windows","desktop-","电脑"].contains(where:text.contains) {return "可能是电脑 · 根据已有名字推测"}
        if ["router","gateway","路由器","网关"].contains(where:text.contains) {return "可能是路由器 · 尚未确认"}
        if ["printer","打印机"].contains(where:text.contains) {return "可能是打印机 · 尚未确认"}
        return "还不知道是手机、电脑还是其他设备"
    }
    static func symbol(_ device:DeviceInfo)->String {
        let type=guess(device)
        if type.contains("手机") && !type.contains("不知道") {return "iphone"}
        if type.contains("平板") {return "ipad"}
        if type.contains("电脑") && !type.contains("不知道") || device.source.contains("本机") {return "desktopcomputer"}
        if type.contains("路由器") {return "wifi.router"}
        if type.contains("打印机") {return "printer"}
        return "questionmark.square.dashed"
    }
}

struct ProcessPage: View {
    @EnvironmentObject private var model:AppModel
    var details:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {Text("本机软件工位 · 以这段记录时间为准").font(.title2.bold());Spacer();Button(model.processBusy ? "正在看这一小段用量…" : "看看谁正在用网") {Task {await model.refreshProcesses()}}.disabled(model.processBusy)}
            Toggle("每十秒自动看一次软件用量",isOn:$model.processAutoEnabled)
            Text(details ? (model.processTraffic?.note ?? "尚无记录") : model.processTraffic?.state == "unknown" ? "这次系统没有给出足够准确的记录，暂时算不出速度。不会把它当成没用网。" : "这是短时间内的平均用量，不会限制软件。VPN 和应用可能重复记账，比例也不代表占满宽带。").foregroundStyle(.secondary)
            if let snapshot=model.processTraffic {Text("这段记录：\(AppModel.time(snapshot.at)) · " + (snapshot.intervalSeconds > 0 ? "约 \(String(format:"%.1f",snapshot.intervalSeconds)) 秒" : "时长暂不确定")).font(.caption).foregroundStyle(.secondary)}
            LazyVGrid(columns:[GridItem(.adaptive(minimum:250),alignment:.top)],spacing:16) {
                ForEach(model.processTraffic?.rows ?? []) {row in
                    VStack(alignment:.leading,spacing:12) {
                        Image(systemName:"app.connected.to.app.below.fill").font(.system(size:30)).foregroundStyle(.blue)
                        Text(Self.friendly(row)).font(.title3.bold()).lineLimit(2)
                        Text("下载 \(AppModel.rate(row.downloadBps))")
                        Text("上传 \(AppModel.rate(row.uploadBps))")
                        ProgressView(value:min(100,max(0,row.observedSharePercent)),total:100).tint(.teal)
                        Text(String(format:"占这次显示的记录 %.1f%%",row.observedSharePercent)).font(.caption).foregroundStyle(.secondary)
                        if details {Text("程序：\(row.name)\nPID：\(row.pid)\n收到字节：\(row.receivedBytes.map { String($0) } ?? "未知")\n发出字节：\(row.sentBytes.map { String($0) } ?? "未知")").font(.caption.monospaced()).textSelection(.enabled)}
                    }.padding(20).frame(maxWidth:.infinity,minHeight:220,alignment:.topLeading).background(Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:16))
                }
            }
        }
    }
    static func friendly(_ row:ProcessTrafficRow)->String {
        if let app=NSRunningApplication(processIdentifier:pid_t(row.pid)),let name=app.localizedName,!name.isEmpty {return name}
        let lower=row.name.lowercased()
        let known:[(String,String)]=[("chrome","Chrome 浏览器"),("safari","Safari 浏览器"),("wechat","微信"),("weixin","微信"),("cursor","Cursor"),("codex","Codex AI"),("clash","Clash 网络代理"),("mihomo","Mihomo 网络代理"),("syncthing","Syncthing 文件同步"),("webkit","Apple 网页组件")]
        return known.first(where:{lower.contains($0.0)})?.1 ?? row.name
    }
}

struct AIPage:View {
    @EnvironmentObject private var model:AppModel
    var details:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {Button(model.isAnalyzing ? "AI 正在看记录…" : "让 AI 帮我看 · 消耗额度") {Task {await model.analyze()}}.disabled(model.isAnalyzing);Button("导出报告") {model.exportReport()};Spacer();Button(model.settings.aiAutoEnabled ? "暂停自动 AI" : "开启自动 AI") {model.toggleAI()} }
            Text(model.aiStatus).font(.callout).foregroundStyle(.secondary)
            if let report=model.aiReport {
                Text(report.summary).font(.largeTitle.bold()).fixedSize(horizontal:false,vertical:true)
                Text(report.primaryCause).font(.title3)
                Text("判断把握："+(report.confidence == "high" ? "较高" : report.confidence == "medium" ? "一般" : "还不够")+" · 分析于 "+(model.lastAIAt.map(AppModel.time) ?? "未知时间")).font(.callout).foregroundStyle(.secondary)
                Text("你现在可以做什么").font(.title2.bold())
                ForEach(Array(report.nextSteps.enumerated()),id:\.offset) {index,step in Label(step,systemImage:"\(index+1).circle.fill").font(.body)}
                Text("为什么这样说").font(.title2.bold())
                LazyVGrid(columns:[GridItem(.adaptive(minimum:230))],spacing:14) {
                    ForEach(Array(report.evidence.enumerated()),id:\.offset) {_,evidence in
                        VStack(alignment:.leading,spacing:9) {Text(evidence.metric).font(.headline);Text(evidence.value).font(.title2.bold()).foregroundStyle(.teal);Text(evidence.meaning).foregroundStyle(.secondary)}.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:14))
                    }
                }
                DisclosureGroup("还可能是什么原因？") {
                    ForEach(Array(report.alternatives.enumerated()),id:\.offset) {_,alternative in VStack(alignment:.leading,spacing:6) {Text(alternative.cause).font(.headline);Text(alternative.reason).foregroundStyle(.secondary)}.padding(.vertical,10).frame(maxWidth:.infinity,alignment:.leading)}
                }
                if details {
                    DisclosureGroup("完整技术分析") {Text(report.details).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
                    DisclosureGroup("这份分析实际收到的数据") {Text(model.lastAIInput).font(.caption.monospaced()).textSelection(.enabled)}
                    DisclosureGroup("下一次分析将使用的新记录") {Text(model.latestPreview).font(.caption.monospaced()).textSelection(.enabled)}
                }
            } else {QuestionCard(title:"AI 还没有结论",conclusion:"先检查，再分析",note:"先完成一次网络检查，AI 才能根据真实记录告诉你哪里值得怀疑。")}
        }
    }
}

struct QuotaPage:View {
    @EnvironmentObject private var model:AppModel
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {Text("账号还剩多少额度").font(.title2.bold());Spacer();Button("刷新额度") {Task {await model.refreshQuota()}}.disabled(model.isRefreshingQuota)}
            Toggle("允许自动 AI 分析（关闭后仍继续记录网络）",isOn:$model.settings.aiAutoEnabled).onChange(of:model.settings.aiAutoEnabled) {_,_ in model.saveSettings()}
            Text("这是账号共享额度，不仅是本软件。查询额度本身不调用模型，也不使用重置机会。").foregroundStyle(.secondary)
            if let error=model.quotaError {Text(error).foregroundStyle(.orange)}
            if let quota=model.quota {
                Text(quota.status+" · "+AppModel.time(quota.at)).foregroundStyle(.secondary)
                ForEach(quota.windows) {window in
                    VStack(alignment:.leading,spacing:10) {
                        HStack {Text(window.name).font(.headline);Spacer();Text(String(format:"还剩 %.1f%%",window.remainingPercent)).font(.title2.bold())}
                        ProgressView(value:window.remainingPercent,total:100).tint(.teal)
                        Text("恢复时间："+(window.resetAt.map(AppModel.time) ?? "账号没有提供")).foregroundStyle(.secondary)
                    }.padding(20).background(Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:14))
                }
                HStack {MetricTile(title:"积分余额",value:quota.creditBalance ?? "暂时不知道");MetricTile(title:"可用重置机会",value:quota.resetCreditsAvailable.map {"\($0) 次"} ?? "暂时不知道")}
                Text("最近到期的重置机会："+(quota.resetCreditExpiresAt.map(AppModel.time) ?? "账号没有提供到期时间"))
            } else {Text("尚未取得额度，需要本机 Codex 已登录。").foregroundStyle(.secondary)}
            Divider()
            HStack {MetricTile(title:"今天尝试分析",value:"\(model.aiCallsToday) 次");MetricTile(title:"输入 token",value:model.aiInputTokensToday.map(String.init) ?? "含未知用量");MetricTile(title:"输出 token",value:model.aiOutputTokensToday.map(String.init) ?? "含未知用量")}
            Text("调用次数有上限，不代表每次 token 固定。失败的调用也可能已经消耗额度。").foregroundStyle(.secondary)
        }
    }
}
