import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: DownloadModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.isRunning == true {
            let alert = NSAlert()
            alert.messageText = "停止下载并退出？"
            alert.informativeText = "已完成的文件会保留，未完成的任务可在下次打开时重试。"
            alert.addButton(withTitle: "停止并退出")
            alert.addButton(withTitle: "继续下载")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        model?.shutdown()
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MusicLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = DownloadModel()
    var body: some Scene {
        Window("Apple Music Local", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.appBecameActive() }
                .frame(minWidth: 1000, minHeight: 760)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 1160, height: 850)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("下载") {
                Button("搜索 Apple Music") { model.selection = "search" }.keyboardShortcut("f", modifiers: [.command])
                Button("账号与登录") { model.openAccount() }
                Button("从剪贴板粘贴链接") { model.pasteLinks() }.keyboardShortcut("v", modifiers: [.command, .shift])
                Button("导入 Cookie 文件…") { model.chooseCookies() }.disabled(model.isRunning || model.importing)
                Button("选择下载文件夹…") { model.chooseFolder() }.disabled(model.isRunning)
                Divider()
                Button("开始下载") { model.startQueue() }.disabled(model.isRunning || model.signingOut || model.importing || model.pendingCount == 0 || !model.engineReady)
                Button("停止下载") { model.stop() }.disabled(!model.isRunning || model.stopping)
                Button("打开下载文件夹") { model.openDownloads() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) { Button("使用帮助") { model.showHelp = true } }
        }
    }
}
