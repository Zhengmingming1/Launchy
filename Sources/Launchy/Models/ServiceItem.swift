import Foundation

/// 「开机自启动」和「系统服务」页面里的一行
struct ServiceItem: Identifiable, Equatable, Sendable {
    enum Scope: String, Sendable {
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
    /// 进程号（来自 launchctl print，可能为空）
    var pid: Int?
    /// 已经停用 / 启用，但 SIP 不让立即卸载，需要重启才生效
    var pendingReboot = false

    /// 给人看的状态：运行中 / 已停止 / 已停用 / 重启后生效
    var statusText: String {
        if pendingReboot { return "重启后生效" }
        if isDisabled { return "已停用" }
        return isRunning ? "运行中" : "已停止"
    }

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
        "com.adobe.AdobeCreativeCloud": ("Adobe Creative Cloud", "Adobe 全家桶后台"),
        "com.google.GoogleUpdater.wake": ("Google 更新唤醒", "定时唤醒 Google 更新程序检查 Chrome 等软件的新版本"),
        "com.google.keystone.xpcservice": ("Google 自动更新", "Google 软件更新的后台组件"),
        "com.tencent.Lemon.monitor": ("腾讯柠檬清理 监控", "柠檬清理的菜单栏监控，显示内存、网速等"),
        "com.tencent.Lemon.trash": ("腾讯柠檬清理 废纸篓监控", "监控废纸篓并提示清理"),
        "com.tencent.LemonDaemon": ("腾讯柠檬清理 后台", "柠檬清理的系统级服务，负责清理和加速"),
        "com.cisco.secureclient.iseposture": ("Cisco 终端合规检查", "Cisco Secure Client 的 ISE Posture 模块，检查电脑是否符合公司网络安全策略"),
        "com.cisco.secureclient.vpnagentd": ("Cisco VPN 服务", "Cisco Secure Client 的 VPN 后台服务"),
        "com.cisco.secureclient.gui": ("Cisco Secure Client", "Cisco VPN 客户端界面"),
        "com.pulsesecure.PulseSetupClient": ("Pulse 安装助手", "Pulse Secure / Ivanti VPN 的组件安装助手"),
        "net.pulsesecure.PulseTray": ("Pulse VPN 托盘", "Pulse Secure / Ivanti VPN 的菜单栏程序"),
        "com.microsoft.autoupdate.helper": ("微软自动更新", "Office 等微软软件的自动更新助手"),
        "com.microsoft.OneDriveStandaloneUpdater": ("OneDrive 更新", "检查 OneDrive 新版本"),
        "com.dropbox.DropboxMacUpdate.agent": ("Dropbox 更新", "检查 Dropbox 新版本"),
        "com.zoom.ZoomDaemon": ("Zoom 后台", "Zoom 会议的系统级服务"),
        "us.zoom.updater": ("Zoom 更新", "检查 Zoom 新版本"),
        "com.teamviewer.service": ("TeamViewer 服务", "远程控制服务，允许别人连接这台电脑"),
        "com.docker.vmnetd": ("Docker 网络", "Docker Desktop 的网络组件"),
        "com.oracle.java.Java-Updater": ("Java 更新", "检查 Java 新版本"),
        "homebrew.mxcl.mysql": ("MySQL 数据库", "通过 Homebrew 安装的 MySQL 数据库服务"),
        "homebrew.mxcl.redis": ("Redis", "通过 Homebrew 安装的 Redis 服务")
    ]

    /// 已知条目的说明
    static func describe(_ label: String) -> String? { known[label]?.1 }

    /// 查不到时，根据标签和程序名里的关键词猜一猜
    static func guess(label: String, program: String?, appName: String?) -> String {
        let text = (label + " " + (program ?? "")).lowercased()
        let owner = appName.map { "「\($0)」的" } ?? ""
        let rules: [(keys: [String], what: String)] = [
            (["update", "updater", "keystone", "upgrade"], "自动更新组件，定期检查有没有新版本。关掉后软件可能不再自动更新"),
            (["wake"], "定时唤醒组件，用来定期叫醒主程序做检查或同步"),
            (["quit"], "自动退出组件，在特定时间关闭某个程序"),
            (["vpn", "secureclient", "pulse", "anyconnect"], "VPN 相关组件。公司电脑上请不要随便关"),
            (["posture", "compliance"], "安全合规检查组件，常见于公司管理的电脑"),
            (["sync", "drive", "cloud"], "同步组件，负责把文件同步到云端"),
            (["helper"], "辅助程序，在后台帮主程序干些杂活"),
            (["monitor"], "监控组件，在后台收集状态信息"),
            (["daemon", "service"], "后台服务"),
            (["agent"], "后台代理程序")
        ]
        for rule in rules where rule.keys.contains(where: { text.contains($0) }) {
            return owner + rule.what + "。"
        }
        return owner.isEmpty ? "暂时不清楚具体用途。可以根据下面的程序路径判断它属于哪个软件。"
                             : owner + "后台组件。"
    }

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
