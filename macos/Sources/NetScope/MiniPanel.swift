import AppKit
import SwiftUI

@MainActor
final class MiniPanelController {
    static let shared = MiniPanelController()
    private var panel: NSPanel?

    func toggle(model: AppModel) {
        if let panel, panel.isVisible { panel.orderOut(nil); return }
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 270, height: 114),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isFloatingPanel = true
            window.level = .floating
            window.hidesOnDeactivate = false
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: FloatingTrafficView(model: model))
            if let screen = NSScreen.main {
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 292, y: screen.visibleFrame.maxY - 138))
            }
            panel = window
        }
        panel?.orderFrontRegardless()
    }
    func hide() { panel?.orderOut(nil) }
    func restoreMain() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
    }
}

private struct FloatingTrafficView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(model.isMonitoring ? Color.mint : Color.orange).frame(width: 6, height: 6)
                Text(model.isMonitoring ? "NETSCOPE · 监测中" : "NETSCOPE · 已暂停")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button { MiniPanelController.shared.hide() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(.system(size: 10)).help("隐藏悬浮窗，监测继续")
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("↓ 下载").font(.caption2).foregroundStyle(.secondary)
                    Text(model.downloadText).font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(.mint)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 3) {
                    Text("↑ 上传").font(.caption2).foregroundStyle(.secondary)
                    Text(model.uploadText).font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(.cyan)
                }
            }
        }
        .padding(16)
        .frame(width: 270, height: 114)
        .background(Color(red: 0.075, green: 0.11, blue: 0.16).opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
        .onTapGesture(count: 2) { MiniPanelController.shared.restoreMain() }
        .help("拖动调整位置；双击还原主窗口")
    }
}
