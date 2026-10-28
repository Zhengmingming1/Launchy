import Foundation

/// 「做什么」
enum TaskAction: Equatable {
    case openApp(String)     // 打开一个程序（.app 路径）
    case runScript(String)   // 运行一个脚本
    case openFile(String)    // 打开一个文件 / 文件夹

    var kind: Kind {
        switch self {
        case .openApp: return .openApp
        case .runScript: return .runScript
        case .openFile: return .openFile
        }
    }

    var path: String {
        switch self {
        case .openApp(let p), .runScript(let p), .openFile(let p): return p
        }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case openApp, runScript, openFile
        var id: String { rawValue }
        var title: String {
            switch self {
            case .openApp: return "打开一个程序"
            case .runScript: return "运行一个脚本"
            case .openFile: return "打开一个文件"
            }
        }
        var icon: String {
            switch self {
            case .openApp: return "app.badge"
            case .runScript: return "terminal"
            case .openFile: return "doc"
            }
        }
    }

    static func make(_ kind: Kind, path: String) -> TaskAction {
        switch kind {
        case .openApp: return .openApp(path)
        case .runScript: return .runScript(path)
        case .openFile: return .openFile(path)
        }
    }

    /// 转成 launchd 的 ProgramArguments
    var programArguments: [String] {
        switch self {
        case .openApp(let p): return ["/usr/bin/open", "-a", p]
        case .runScript(let p): return ["/bin/zsh", p]
        case .openFile(let p): return ["/usr/bin/open", p]
        }
    }

    /// 从 ProgramArguments 反推回来（只认识本软件自己生成的格式）
    init?(arguments: [String]) {
        if arguments.count == 3, arguments[0] == "/usr/bin/open", arguments[1] == "-a" {
            self = .openApp(arguments[2])
        } else if arguments.count == 2, arguments[0] == "/usr/bin/open" {
            self = .openFile(arguments[1])
        } else if arguments.count == 2, arguments[0] == "/bin/zsh" {
            self = .runScript(arguments[1])
        } else {
            return nil
        }
    }
}

/// 「什么时候」
enum TaskSchedule: Equatable {
    case every(minutes: Int)
    case daily(hour: Int, minute: Int)
    case atLogin

    enum Kind: String, CaseIterable, Identifiable {
        case every, daily, atLogin
        var id: String { rawValue }
        var title: String {
            switch self {
            case .every: return "每隔一段时间"
            case .daily: return "每天固定时间"
            case .atLogin: return "开机时"
            }
        }
        var icon: String {
            switch self {
            case .every: return "arrow.clockwise"
            case .daily: return "calendar"
            case .atLogin: return "bolt"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .every: return .every
        case .daily: return .daily
        case .atLogin: return .atLogin
        }
    }

    /// 给人看的说法
    var humanText: String {
        switch self {
        case .every(let m):
            if m % 60 == 0 { return "每隔 \(m / 60) 小时" }
            return "每隔 \(m) 分钟"
        case .daily(let h, let m):
            return String(format: "每天 %02d:%02d", h, m)
        case .atLogin:
            return "开机登录时"
        }
    }
}

/// 一个「我的任务」，对应 ~/Library/LaunchAgents/com.launchy.xxx.plist
struct MyTask: Identifiable, Equatable {
    static let labelPrefix = "com.launchy."

    var label: String
    var name: String
    var action: TaskAction
    var schedule: TaskSchedule

    // 以下是运行时状态，不写进 plist
    var isPaused = false
    var isLoaded = false
    var lastExitStatus: Int?
    /// 本次加载以来运行过几次（重启电脑、暂停后恢复、保存修改后会从 0 重新数）
    var runCount: Int?
    /// 要打开 / 运行的程序、脚本或文件已经确定不存在了（被移走或删除）
    var targetMissing = false

    /// 目标文件给人看的名字，例如「微信」「备份」
    var targetName: String {
        URL(fileURLWithPath: action.path).deletingPathExtension().lastPathComponent
    }

    /// 出问题时建议用户做的下一步（「怎么修」按钮）
    enum FixIt: Equatable {
        case rechoose   // 目标文件找不到了：重新选择
        case viewLog    // 运行失败：看运行记录里的详细原因

        var title: String {
            switch self {
            case .rechoose: return "重新选择…"
            case .viewLog: return "查看运行记录"
            }
        }
    }

    /// 当前最该做的修复动作；没问题时为 nil
    var fixIt: FixIt? {
        if targetMissing { return .rechoose }
        if lastRunFailed { return .viewLog }
        return nil
    }

    /// 是否需要用户注意（文件丢了，或者上次运行失败）
    var needsAttention: Bool { targetMissing || lastRunFailed }

    /// 上次运行的结果，给人看的一句话；暂停或没加载时为 nil
    var lastRunText: String? {
        // 文件丢了最要紧：不管暂停与否都先说清楚，免得恢复后才发现跑不起来
        if targetMissing { return "找不到「\(targetName)」了，可能被移走或删除，重新选一下就好" }
        guard isLoaded, !isPaused else { return nil }
        guard let runs = runCount, runs > 0 else {
            // 拿不到次数时，至少根据退出码说一句
            if let code = lastExitStatus, code != 0 { return "上次运行失败：" + TaskExitReason.text(code, action: action) }
            return runCount == 0 ? "还没运行过，右键「立即运行一次」可以先试试" : nil
        }
        let times = "本次启用以来运行了 \(runs) 次"
        guard let code = lastExitStatus else { return "正在运行 · " + times }
        if code == 0 { return "上次运行成功 · " + times }
        return "上次运行失败：" + TaskExitReason.text(code, action: action) + " · " + times
    }

    /// 上次运行是否失败
    var lastRunFailed: Bool { !isPaused && (lastExitStatus ?? 0) != 0 }

    var id: String { label }

    /// 一句话总结，例如「每隔 60 分钟，自动打开「清理下载」。」
    var summary: String {
        TaskSummary.make(action: action, schedule: schedule)
    }

    var plistURL: URL { Paths.userAgents.appendingPathComponent("\(label).plist") }
    var logURL: URL { Paths.logs.appendingPathComponent("\(label).log") }

    /// 生成 launchd 能读懂的字典
    func toPlist() -> [String: Any] {
        var dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": action.programArguments,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            // 自定义字段：launchd 会忽略它，我们用来保存好听的名字
            "LaunchyName": name
        ]
        switch schedule {
        case .every(let minutes):
            dict["StartInterval"] = max(1, minutes) * 60
        case .daily(let hour, let minute):
            dict["StartCalendarInterval"] = ["Hour": hour, "Minute": minute]
        case .atLogin:
            dict["RunAtLoad"] = true
        }
        return dict
    }

    /// 从 plist 字典读回来；不是本软件格式的返回 nil
    init?(plist: [String: Any]) {
        guard let label = plist["Label"] as? String,
              label.hasPrefix(MyTask.labelPrefix),
              let args = plist["ProgramArguments"] as? [String],
              let action = TaskAction(arguments: args) else { return nil }
        self.label = label
        self.name = (plist["LaunchyName"] as? String) ?? label
        self.action = action
        if let seconds = plist["StartInterval"] as? Int {
            self.schedule = .every(minutes: max(1, seconds / 60))
        } else if let cal = plist["StartCalendarInterval"] as? [String: Any] {
            self.schedule = .daily(hour: cal["Hour"] as? Int ?? 0, minute: cal["Minute"] as? Int ?? 0)
        } else {
            self.schedule = .atLogin
        }
    }

    init(name: String, action: TaskAction, schedule: TaskSchedule) {
        self.label = MyTask.labelPrefix + UUID().uuidString.prefix(8).lowercased()
        self.name = name
        self.action = action
        self.schedule = schedule
    }
}

/// 把退出码翻译成人话
enum TaskExitReason {
    static func text(_ code: Int, action: TaskAction) -> String {
        if code < 0 { return "被系统强制结束了（信号 \(-code)）" }
        switch code {
        case 1 where action.kind != .runScript:
            return "没能打开，要打开的程序或文件可能被移走或删除了"
        case 126: return "脚本没有执行权限"
        case 127: return "脚本里有找不到的命令"
        case 78: return "配置有问题，launchd 拒绝运行"
        case 128...: return "被系统强制结束了（信号 \(code - 128)）"
        default: return "退出码 \(code)，运行记录里有详细信息"
        }
    }
}

enum TaskSummary {
    static func make(action: TaskAction, schedule: TaskSchedule) -> String {
        let target = action.path.isEmpty
            ? "（还没选）"
            : "「" + URL(fileURLWithPath: action.path).deletingPathExtension().lastPathComponent + "」"
        let verb: String
        switch action.kind {
        case .openApp: verb = "打开程序"
        case .runScript: verb = "运行脚本"
        case .openFile: verb = "打开文件"
        }
        return "\(schedule.humanText)，自动\(verb)\(target)。"
    }
}

/// 常用路径
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let userAgents = home.appendingPathComponent("Library/LaunchAgents")
    static let logs = home.appendingPathComponent("Library/Logs/Launchy")
    static let support = home.appendingPathComponent("Library/Application Support/Launchy")

    static let globalAgents = URL(fileURLWithPath: "/Library/LaunchAgents")
    static let globalDaemons = URL(fileURLWithPath: "/Library/LaunchDaemons")
    static let systemAgents = URL(fileURLWithPath: "/System/Library/LaunchAgents")
    static let systemDaemons = URL(fileURLWithPath: "/System/Library/LaunchDaemons")
}
