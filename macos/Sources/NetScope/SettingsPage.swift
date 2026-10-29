import SwiftUI

struct SettingsPage:View {
    @EnvironmentObject private var model:AppModel
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            HStack {Text("你决定要看什么").font(.title2.bold());Spacer();Button("保存我的设置") {model.saveSettings()}.buttonStyle(.borderedProminent)}
            Text(model.settingsMessage).foregroundStyle(.teal)
            GroupBox("后台记录") {
                VStack(alignment:.leading,spacing:16) {
                    Toggle("打开软件就开始记录",isOn:$model.settings.autoMonitor)
                    Toggle("发现值得留意的情况时弹出通知",isOn:$model.settings.notificationsEnabled)
                    Stepper("每 \(model.settings.intervalSeconds) 秒检查网站",value:$model.settings.intervalSeconds,in:15...3600,step:15)
                    Stepper("每次最多等待 \(model.settings.timeoutSeconds) 秒",value:$model.settings.timeoutSeconds,in:3...20)
                    Stepper("保留 \(model.settings.retentionDays) 天记录",value:$model.settings.retentionDays,in:1...90)
                    Picker("统计哪条连接的用量",selection:$model.settings.trafficAdapterID) {
                        Text("自动选择主要连接").tag("auto")
                        ForEach(model.local?.adapters ?? []) {adapter in Text(adapter.name+(adapter.isVirtual ? "（可能是 VPN）" : "")).tag(adapter.id)}
                    }
                    Text("只统计一条连接，避免把 VPN 和实际网卡的同一份流量加两遍。流量数字不是宽带最大速度。").font(.callout).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
            }
            GroupBox("AI 帮忙的频率") {
                VStack(alignment:.leading,spacing:16) {
                    Toggle("自动分析",isOn:$model.settings.aiAutoEnabled)
                    Toggle("出现新问题时提前分析（至少隔五分钟）",isOn:$model.settings.aiOnAnomaly)
                    Stepper("平时每 \(model.settings.aiIntervalMinutes) 分钟分析一次",value:$model.settings.aiIntervalMinutes,in:5...1440,step:5)
                    Stepper("每天最多 \(model.settings.maxAiCallsPerDay) 次",value:$model.settings.maxAiCallsPerDay,in:0...200)
                    TextField("Codex 程序位置（留空自动寻找）",text:$model.settings.codexPath)
                    Text("会使用本机 Codex 的登录。关闭 AI 后，原始网络记录仍继续；真实调用会消耗你的账号额度。").foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
            }
            HStack {Text("我关心的网站和应用").font(.title2.bold());Spacer();Button("添加自己的地址") {model.addTarget()} }
            Text("勾选才会自动检查。可以加入公司内部页面；输入完整 https:// 地址。").foregroundStyle(.secondary)
            ForEach($model.settings.targets) {$target in
                HStack(alignment:.top,spacing:12) {
                    Toggle("检查",isOn:$target.enabled).labelsHidden()
                    VStack(alignment:.leading,spacing:8) {TextField("名字",text:$target.name);TextField("网址",text:$target.url).font(.callout.monospaced())}
                    TextField("分组",text:$target.group).frame(width:85)
                    Button(role:.destructive) {model.removeTarget(id:target.id)} label:{Image(systemName:"trash")}
                }.padding(14).background(Color.secondary.opacity(0.07),in:RoundedRectangle(cornerRadius:10))
            }
            Button("保存我的设置") {model.saveSettings()}.buttonStyle(.borderedProminent)
            if let directory=model.dataDirectory {DisclosureGroup("查看记录保存位置") {Text(directory.path).font(.caption.monospaced()).textSelection(.enabled)}}
        }
    }
}
