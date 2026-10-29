import SwiftUI
import AppKit

@main
struct NetScopeApp: App {
    @NSApplicationDelegateAdaptor(NetScopeAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("NetScope · 上网助手", id: "main") {
            DashboardView()
                .environmentObject(model)
                .frame(minWidth: 1060, minHeight: 720)
                
                .task { model.start() }
        }
        .defaultSize(width: 1360, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("监测") {
                Button(model.isMonitoring ? "暂停本地监测" : "恢复本地监测") { model.toggleMonitoring() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("检查为什么卡") { Task { await model.runCheck() } }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("显示 / 隐藏悬浮窗") { MiniPanelController.shared.toggle(model: model) }
            }
        }
        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Label(model.isMonitoring ? "↓ \(model.downloadText)" : "NetScope 已暂停", systemImage: "waveform.path.ecg")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class NetScopeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { AppModel.shared.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil) }
        return true
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("NetScope 上网助手")
        Text("下载 \(model.downloadText) · 上传 \(model.uploadText)")
        Divider()
        Button("打开上网助手") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(model.isMonitoring ? "暂停本地监测" : "恢复本地监测") { model.toggleMonitoring() }
        Button("检查为什么卡") { Task { await model.runCheck() } }.disabled(model.isChecking)
        Button("显示 / 隐藏悬浮窗") { MiniPanelController.shared.toggle(model: model) }
        Divider()
        Button(model.settings.aiAutoEnabled ? "暂停自动 AI" : "启用自动 AI") { model.toggleAI() }
        Text("本应用今日 AI \(model.aiCallsToday) 次")
        Divider()
        Button("退出 NetScope") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
