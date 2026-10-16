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
    /// 是否有「重启后才生效」的修改
    @Published private(set) var pendingReboot: Set<String> = []
    @Published private(set) var isRefreshing = false

    /// launchctl print 的结果缓存几秒，避免切页面时反复查询
    private var stateCache: [String: (time: Date, state: Launchctl.ServiceState)] = [:]
    private let cacheSeconds: TimeInterval = 5

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
        applyCachedStates()
        refreshStates()
    }

    /// 把缓存里的运行状态填到列表上
    private func applyCachedStates() {
        func apply(_ list: inout [ServiceItem]) {
            for i in list.indices {
                list[i].pendingReboot = pendingReboot.contains(list[i].id)
                if let cached = stateCache[list[i].id] {
                    list[i].isRunning = cached.state.running
                    list[i].pid = cached.state.pid
                }
            }
        }
        apply(&startupItems)
        apply(&systemItems)
    }

    /// 在后台批量执行 launchctl print，查询过期的条目，查完回到主线程更新界面
    func refreshStates(force: Bool = false) {
        let now = Date()
        let all = startupItems + systemItems
        let stale = all.filter { item in
            force || stateCache[item.id].map { now.timeIntervalSince($0.time) > cacheSeconds } ?? true
        }
        guard !stale.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        let queries = stale.map { (domain: $0.scope.domain, label: $0.label) }
        let ids = stale.map(\.id)
        DispatchQueue.global(qos: .userInitiated).async {
            let states = Launchctl.states(queries)
            DispatchQueue.main.async {
                let time = Date()
                for (id, st) in zip(ids, states) { self.stateCache[id] = (time, st) }
                self.isRefreshing = false
                self.applyCachedStates()
            }
        }
    }

    // MARK: - 开关

    /// 打开或关闭一个服务，尽量立即生效：
    /// - 停用：launchctl disable，然后 bootout（马上停掉）
    /// - 启用：launchctl enable，然后 bootstrap（马上加载）
    /// 两步合成一条命令；需要管理员的只弹一次密码框。
    /// 苹果系统服务常常因为 SIP 无法 bootout，这时标记为「重启后生效」。
    func setEnabled(_ item: ServiceItem, _ enabled: Bool) {
        let target = "\(item.scope.domain)/\(item.label)"
        let q = Shell.shellQuote
        let marker = "__LAUNCHY_STEP2_FAILED__"
        let script: String
        if enabled {
            script = "\(q(Launchctl.path)) enable \(q(target)) && "
                + "{ \(q(Launchctl.path)) bootstrap \(q(item.scope.domain)) \(q(item.plistURL.path)) 2>&1 || echo \(marker); }"
        } else {
            script = "\(q(Launchctl.path)) disable \(q(target)) && "
                + "{ \(q(Launchctl.path)) bootout \(q(target)) 2>&1 || echo \(marker); }"
        }

        let r = item.scope.needsAdmin ? Shell.runAsAdmin(script: script) : Shell.run("/bin/sh", ["-c", script])
        guard r.ok else {
            // 第一步就失败了（或者用户在密码框点了取消）
            lastError = "没有完成：\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            reload()
            return
        }

        if r.output.contains(marker) {
            // 第二步失败。启用时「已经加载」也会报错，那其实没问题，只有系统服务才提示重启。
            let isApple = item.scope == .systemAgent || item.scope == .systemDaemon
            if isApple || !enabled { pendingReboot.insert(item.id) }
        } else {
            pendingReboot.remove(item.id)
        }

        history.insert(ChangeRecord(date: Date(), label: item.label,
                                    scope: item.scope.rawValue, disabled: !enabled), at: 0)
        saveHistory()
        stateCache[item.id] = nil
        reload()
    }

    /// 立即重启电脑（会走系统正常的重启流程，未保存的文档会提示保存）
    func restartNow() {
        Shell.run("/usr/bin/osascript", ["-e", "tell application \"loginwindow\" to «event aevtrrst»"])
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
