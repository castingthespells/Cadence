import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 关掉窗口就直接退出，不做后台驻留
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments

        // 自绘截图：不依赖屏幕录制权限，ad-hoc 重签后也不会失效
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            let base = args[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                AppDelegate.saveSnapshots(base: base)
            }
        }
    }

    static func saveSnapshots(base: String) {
        var index = 0
        for window in NSApp.windows {
            guard window.isVisible, window.frame.height > 100 else { continue }
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let suffix = index == 0 ? "" : "-\(index)"
            try? data.write(to: URL(fileURLWithPath: base + suffix + ".png"))
            index += 1
        }
    }
}

@main
struct CadenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = PlayerModel()

    var body: some Scene {
        WindowGroup("Cadence") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1120, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加音乐文件夹…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("重新扫描") { model.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
            }

            CommandGroup(replacing: .appInfo) {
                Button("关于 Cadence") {
                    NSApplication.shared.orderFrontStandardAboutPanel(nil)
                }
            }


            CommandMenu("播放") {
                Button(model.isPlaying ? "暂停" : "播放") { model.togglePlay() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("下一首") { model.next() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("上一首") { model.previous() }
                    .keyboardShortcut("[", modifiers: .command)

                Divider()

                Button("切换随机模式（\(model.shuffleMode.shortLabel)）") { model.cycleShuffle() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("切换循环模式（\(model.repeatMode.label)）") { model.cycleRepeat() }
                    .keyboardShortcut("l", modifiers: .command)

                Divider()

                Button(model.showMeters ? "收起仪表" : "展开仪表") { model.showMeters.toggle() }
                    .keyboardShortcut("m", modifiers: .command)
                Button("听歌统计") { model.showingStats = true }
                    .keyboardShortcut("t", modifiers: .command)
                Button("一起听…") { model.showingSync = true }
                    .keyboardShortcut("j", modifiers: [.command, .shift])

                Divider()

                Button("调高音量") { model.volume = min(1, model.volume + 0.1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("调低音量") { model.volume = max(0, model.volume - 0.1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
