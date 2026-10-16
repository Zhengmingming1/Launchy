import Foundation

/// 「开机自启动」和「系统服务」页面里的一行
struct ServiceItem: Identifiable, Equatable {
    enum Scope: String {
        case user        // ~/Library/LaunchAgents
        case allUsers    // /Library/LaunchAgents
        case daemon      // /Library/LaunchDaemons（需要管理员）
        case systemAgent // /System/Library/LaunchAgents（SIP 保护）
        case systemDaemon// /System/Library/LaunchDaemons（SIP 保护）

        /// 这个服务属于 launchctl 的哪个域
        var domain: String {
            switch self {
            case .user, .allUsers, .systemAgent: return Launchctl.userDomain
            case .daemon, .systemDaemon: return Launchctl.systemDomain
            }
        }

        /// 是否需要管理员密码
        var needsAdmin: Bool { domain == Launchctl.systemDomain }

        var title: String {
            switch self {
            case .user: return "仅当前用户"
            case .allUsers: return "所有用户"
            case .daemon: return "系统级（修改需要管理员密码）"
            case .systemAgent: return "苹果 · 用户服务"
            case .systemDaemon: return "苹果 · 系统服务"
            }
        }
    }

    let label: String
    let plistURL: URL
    let scope: Scope
    let program: String?
    var isDisabled: Bool
    var isRunning: Bool

    var id: String { scope.rawValue + "/" + label }

    var friendlyName: String { FriendlyNames.name(for: label, program: program) }
    var detail: String { FriendlyNames.detail(for: label) ?? label }
}

/// 把难懂的 com.xxx.yyy 翻译成人话。查不到就尽量从标签里猜。
enum FriendlyNames {
    private static let known: [String: (String, String)] = [
        "com.apple.suggestd": ("Siri 建议", "为 Siri 和聚焦搜索提供建议"),
        "com.apple.bluetoothd": ("蓝牙", "关闭后蓝牙键盘、耳机等无法使用"),
        "com.apple.photoanalysisd": ("照片分析", "识别照片中的人物和物体"),
        "com.apple.cloudd": ("iCloud 同步", "同步 iCloud 云盘、备忘录等"),
        "com.apple.gamed": ("游戏中心", "Game Center 好友和成就"),
        "com.apple.Siri.agent": ("Siri", "语音助手"),
        "com.apple.mediaanalysisd": ("媒体分析", "分析照片和视频内容"),
        "com.apple.spindump": ("卡顿诊断", "程序无响应时收集诊断信息"),
        "com.apple.ReportCrash": ("崩溃报告", "程序崩溃时生成报告"),
        "com.apple.screensharing": ("屏幕共享", "允许别人远程查看这台电脑"),
        "com.apple.AirPlayXPCHelper": ("隔空播放", "AirPlay 投屏"),
        "com.apple.mdworker.shared": ("聚焦索引", "为聚焦搜索建立文件索引"),
        "com.google.keystone.daemon": ("Google 自动更新", "Chrome 等 Google 软件的更新"),
        "com.google.keystone.agent": ("Google 自动更新", "Chrome 等 Google 软件的更新"),
        "com.microsoft.update.agent": ("微软自动更新", "Office 等微软软件的更新"),
        "com.adobe.AdobeCreativeCloud": ("Adobe Creative Cloud", "Adobe 全家桶后台")
    ]

    static func name(for label: String, program: String?) -> String {
        if let hit = known[label] { return hit.0 }
        // 能找到所属 .app 就用 app 的名字
        if let program, let range = program.range(of: ".app/") {
            let appPath = String(program[..<range.lowerBound])
            return URL(fileURLWithPath: appPath).lastPathComponent
        }
        // 否则取标签最后一段，例如 com.foo.helper -> helper
        return label.split(separator: ".").last.map(String.init) ?? label
    }

    static func detail(for label: String) -> String? {
        known[label].map { "\(label) · \($0.1)" }
    }
}
