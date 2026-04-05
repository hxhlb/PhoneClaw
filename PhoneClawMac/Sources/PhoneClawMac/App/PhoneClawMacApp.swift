import SwiftUI
import AppKit
import Foundation

/// 输出到 stderr（GUI 进程的 stdout 不可见）
func log(_ items: Any...) {
    let msg = items.map { String(describing: $0) }.joined(separator: " ")
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

@main
struct PhoneClawMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 500, idealWidth: 600, minHeight: 700, idealHeight: 800)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 600, height: 800)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 命令行启动 SwiftUI 必须手动设置，否则窗口不显示
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 确保窗口在最前面
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}
