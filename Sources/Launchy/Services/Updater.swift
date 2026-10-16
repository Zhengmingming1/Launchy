import SwiftUI
import Sparkle
import Combine

/// Sparkle 自动更新的封装。
/// 配置都在 Info.plist 里：SUFeedURL（更新源）、SUPublicEDKey（验签公钥）、
/// SUEnableAutomaticChecks（默认自动检查）、SUScheduledCheckInterval（每天一次）。
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false

    /// 用 swift run 直接跑（不是 .app）时没有 Info.plist 配置，这时不启动更新器，免得报错
    let isAvailable: Bool

    init() {
        let available = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        isAvailable = available
        controller = SPUStandardUpdaterController(startingUpdater: available,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// 「自动检查更新」开关
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }
}

/// 菜单栏「启动台助手」下的「检查更新…」
struct CheckForUpdatesCommand: Commands {
    @ObservedObject var updater: Updater
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") { updater.checkForUpdates() }
                .disabled(!updater.isAvailable || !updater.canCheckForUpdates)
        }
    }
}

/// 设置窗口（⌘,）
struct SettingsView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Form {
            Toggle("自动检查更新", isOn: Binding(get: { updater.automaticallyChecks },
                                                set: { updater.automaticallyChecks = $0 }))
                .disabled(!updater.isAvailable)
            Text("每天检查一次。有新版本会先问你，你同意了才会安装。")
                .font(.caption).foregroundStyle(.secondary)
            Button("立即检查更新…") { updater.checkForUpdates() }
                .disabled(!updater.isAvailable || !updater.canCheckForUpdates)
            if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text("当前版本：\(v)　·　更新源：GitHub").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
