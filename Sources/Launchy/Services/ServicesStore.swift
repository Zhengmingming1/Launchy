import Foundation

/// 一条修改记录，用来「恢复默认」
struct ChangeRecord: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let label: String
    let scope: String      // ServiceItem.Scope.rawValue
    let disabled: Bool     // true = 这次是停用
}

/// 管理「开机自启动」和「系统服务」两页的数据
@MainActor
final class ServicesStore: ObservableObject {
    @Published private(set) var startupItems: [ServiceItem] = []
    @Published private(set) var systemItems: [ServiceItem] = []
    @Published private(set) var history: [ChangeRecord] = []
    @Published var lastError: String?

    private let historyURL = Paths.support.appendingPathComponent("history.json")

    init() {
        loadHistory()
        reload()
    }

    // MARK: - 扫描

    func reload() {
        let loaded = Launchctl.loadedJobs()
        let userDisabled = Launchctl.disabledLabels(domain: Launchctl.userDomain)
        let systemDisabled = Launchctl.disabledLabels(domain: Launchctl.systemDomain)

        func scan(_ dir: URL, _ scope: ServiceItem.Scope) -> [ServiceItem] {
            PlistIO.plists(in: dir).compactMap { url in
                guard let dict = PlistIO.read(url), let label = dict["Label"] as? String else { return nil }
                // 本软件自己的任务在「我的任务」里管理
                if label.hasPrefix(MyTask.labelPrefix) { return nil }
                let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
                let disabledSet = scope.domain == Launchctl.systemDomain ? systemDisabled : userDisabled
                // plist 里自带 Disabled=true 且没被覆盖时也算关闭（简化处理）
                let plistDisabled = dict["Disabled"] as? Bool ?? false
                return ServiceItem(label: label, plistURL: url, scope: scope, program: program,
                                   isDisabled: disabledSet.contains(label) || plistDisabled,
                                   isRunning: loaded[label]?.pid != nil)
            }
        }

        startupItems = scan(Paths.userAgents, .user)
            + scan(Paths.globalAgents, .allUsers)
            + scan(Paths.globalDaemons, .daemon)
        systemItems = scan(Paths.systemAgents, .systemAgent)
            + scan(Paths.systemDaemons, .systemDaemon)
    }

    // MARK: - 开关

    /// 打开或关闭一个服务。
    /// - 第三方服务：enable/disable + 立即加载/卸载
    /// - 苹果系统服务：受 SIP 保护，只做 enable/disable，重启后生效
    func setEnabled(_ item: ServiceItem, _ enabled: Bool) {
        let target = "\(item.scope.domain)/\(item.label)"
        let isApple = item.scope == .systemAgent || item.scope == .systemDaemon

        var commands: [[String]] = [[Launchctl.path, enabled ? "enable" : "disable", target]]
        if !isApple {
            commands.append(enabled
                ? [Launchctl.path, "bootstrap", item.scope.domain, item.plistURL.path]
                : [Launchctl.path, "bootout", target])
        }

        let ok: Bool
        if item.scope.needsAdmin {
            let r = Shell.runAsAdmin(commands)
            // 用户点了「取消」时 osascript 返回非零，忽略加载阶段的报错，只看整体
            ok = r.ok
            if !ok { lastError = "没有完成：\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))" }
        } else {
            let first = Shell.run(commands[0][0], Array(commands[0].dropFirst()))
            ok = first.ok
            // 加载/卸载失败（比如本来就没加载）不算错误
            if commands.count > 1 { Shell.run(commands[1][0], Array(commands[1].dropFirst())) }
            if !ok { lastError = "没有完成：\(first.output)" }
        }

        if ok {
            history.insert(ChangeRecord(date: Date(), label: item.label,
                                        scope: item.scope.rawValue, disabled: !enabled), at: 0)
            saveHistory()
        }
        reload()
    }

    // MARK: - 恢复默认

    /// 被本软件停用、到现在还没重新打开的服务
    var pendingRestores: [ChangeRecord] {
        var latest: [String: ChangeRecord] = [:]
        // history 最新在前，所以第一次遇到的就是最终状态
        for record in history where latest[record.scope + "/" + record.label] == nil {
            latest[record.scope + "/" + record.label] = record
        }
        return latest.values.filter { $0.disabled }
    }

    /// 把所有通过本软件停用的服务重新启用。需要管理员的合并成一次密码框。
    func restoreDefaults() {
        let pending = pendingRestores
        guard !pending.isEmpty else { return }
        var adminCommands: [[String]] = []
        for record in pending {
            guard let scope = ServiceItem.Scope(rawValue: record.scope) else { continue }
            let cmd = [Launchctl.path, "enable", "\(scope.domain)/\(record.label)"]
            if scope.needsAdmin { adminCommands.append(cmd) } else { Shell.run(cmd[0], Array(cmd.dropFirst())) }
        }
        if !adminCommands.isEmpty {
            let r = Shell.runAsAdmin(adminCommands)
            if !r.ok { lastError = "部分系统级服务没有恢复：\(r.output)"; reload(); return }
        }
        for record in pending {
            history.insert(ChangeRecord(date: Date(), label: record.label,
                                        scope: record.scope, disabled: false), at: 0)
        }
        saveHistory()
        reload()
    }

    // MARK: - 历史记录持久化

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL) else { return }
        history = (try? JSONDecoder().decode([ChangeRecord].self, from: data)) ?? []
    }

    private func saveHistory() {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }
}
