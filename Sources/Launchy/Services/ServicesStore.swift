import Foundation

/// 一条修改记录，用来「恢复默认」
struct ChangeRecord: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let label: String
    let scope: String      // ServiceItem.Scope.rawValue
    let disabled: Bool     // true = 这次是停用
}

/// 「重启后生效」标记，连同记录时的开机时间一起保存；开机时间变了就说明已经重启过
private struct PendingRebootFile: Codable {
    let bootTime: Int
    let ids: [String]
}

/// 管理「开机自启动」和「系统服务」两页的数据。
/// 所有 launchctl 调用都放在后台线程，主线程只负责更新界面。
@MainActor
final class ServicesStore: ObservableObject {
    @Published private(set) var startupItems: [ServiceItem] = []
    @Published private(set) var systemItems: [ServiceItem] = []
    @Published private(set) var history: [ChangeRecord] = []
    @Published var lastError: String?
    /// 有「重启后才生效」的修改
    @Published private(set) var pendingReboot: Set<String> = []
    @Published private(set) var isRefreshing = false
    /// 第一次扫描还没完成
    @Published private(set) var isLoading = true
    /// 正在执行开关操作（可能在等密码框）
    @Published private(set) var isWorking = false

    /// 运行状态缓存几秒，避免切页面时反复查询
    private var stateCache: [String: (time: Date, state: Launchctl.ServiceState)] = [:]
    private let cacheSeconds: TimeInterval = 5
    private var scanGeneration = 0

    private let historyURL = Paths.support.appendingPathComponent("history.json")
    private let pendingURL = Paths.support.appendingPathComponent("pending-reboot.json")
    private let historyLimit = 500

    init() {
        loadHistory()
        loadPendingReboot()
        reload()
    }

    // MARK: - 扫描

    /// 在后台扫描所有 plist，并读取停用状态
    func reload() {
        scanGeneration += 1
        let generation = scanGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let (startup, system) = Self.scanAll()
            DispatchQueue.main.async {
                // 期间又触发了新的扫描，就丢掉这次旧结果
                guard generation == self.scanGeneration else { return }
                self.startupItems = startup
                self.systemItems = system
                self.isLoading = false
                self.applyCachedStates()
                self.refreshStates()
            }
        }
    }

    /// 纯函数：扫描目录 + 读取覆盖设置，不碰界面状态，可以在后台线程跑
    nonisolated private static func scanAll() -> ([ServiceItem], [ServiceItem]) {
        let userOverrides = Launchctl.overrides(domain: Launchctl.userDomain)
        let systemOverrides = Launchctl.overrides(domain: Launchctl.systemDomain)

        func scan(_ dir: URL, _ scope: ServiceItem.Scope) -> [ServiceItem] {
            PlistIO.plists(in: dir).compactMap { url in
                guard let dict = PlistIO.read(url), let label = dict["Label"] as? String else { return nil }
                // 本软件自己的任务在「我的任务」里管理
                if label.hasPrefix(MyTask.labelPrefix) { return nil }
                let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
                let overrides = scope.domain == Launchctl.systemDomain ? systemOverrides : userOverrides
                // 以 launchctl 的覆盖设置为准；没有覆盖时才看 plist 里的 Disabled
                let disabled = overrides[label] ?? (dict["Disabled"] as? Bool ?? false)
                var item = ServiceItem(label: label, plistURL: url, scope: scope, program: program,
                                       isDisabled: disabled, isRunning: false)
                // 苹果自带的服务不做这项检查，避免误导用户去动系统服务
                if scope != .systemAgent && scope != .systemDaemon {
                    item.programMissing = ServiceItem.isProgramMissing(program)
                }
                return item
            }
        }

        let startup = scan(Paths.userAgents, .user)
            + scan(Paths.globalAgents, .allUsers)
            + scan(Paths.globalDaemons, .daemon)
        let system = scan(Paths.systemAgents, .systemAgent)
            + scan(Paths.systemDaemons, .systemDaemon)
        return (startup, system)
    }

    /// 把缓存里的运行状态和重启标记填到列表上
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

    /// 在后台刷新运行状态。每个域只调用一次 launchctl print，几百个服务也很快。
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

    private struct ToggleOutcome {
        var firstStepError: String?   // 第一步（enable/disable）失败
        var secondStepError: String?  // 第二步（bootstrap/bootout）失败，且服务状态不符合预期
    }

    /// 打开或关闭一个服务，尽量立即生效：
    /// - 停用：launchctl disable，然后 bootout（马上停掉）
    /// - 启用：launchctl enable，然后 bootstrap（马上加载）
    /// 两步合成一条命令，需要管理员的只弹一次密码框。整个过程在后台执行，界面不会卡住。
    func setEnabled(_ item: ServiceItem, _ enabled: Bool) {
        guard !isWorking else { return }
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.performToggle(item, enabled)
            DispatchQueue.main.async { self.finishToggle(item, enabled, outcome) }
        }
    }

    nonisolated private static func performToggle(_ item: ServiceItem, _ enabled: Bool) -> ToggleOutcome {
        let target = "\(item.scope.domain)/\(item.label)"
        let q = Shell.shellQuote
        let lc = q(Launchctl.path)
        let marker = "__LAUNCHY_STEP2_FAILED__"
        // 第二步失败时先输出标记，再输出错误信息，方便区分
        let script: String
        if enabled {
            script = "\(lc) enable \(q(target)) && "
                + "{ out=$(\(lc) bootstrap \(q(item.scope.domain)) \(q(item.plistURL.path)) 2>&1) || echo \"\(marker)$out\"; }"
        } else {
            script = "\(lc) disable \(q(target)) && "
                + "{ out=$(\(lc) bootout \(q(target)) 2>&1) || echo \"\(marker)$out\"; }"
        }

        let r = item.scope.needsAdmin ? Shell.runAsAdmin(script: script) : Shell.run("/bin/sh", ["-c", script])
        guard r.ok else { return ToggleOutcome(firstStepError: r.output) }
        guard let range = r.output.range(of: marker) else { return ToggleOutcome() }

        // 第二步报错了，用实际状态判断：启用后已经加载、停用后已经卸载，都算成功
        // （比如「已经加载过了」会报错，但其实没问题）
        let loadedNow = Launchctl.isLoaded(domain: item.scope.domain, label: item.label)
        if enabled == loadedNow { return ToggleOutcome() }
        return ToggleOutcome(secondStepError: String(r.output[range.upperBound...]))
    }

    private func finishToggle(_ item: ServiceItem, _ enabled: Bool, _ outcome: ToggleOutcome) {
        isWorking = false
        if let error = outcome.firstStepError {
            lastError = FriendlyError.text(error)
            reload()
            return
        }

        let isApple = item.scope == .systemAgent || item.scope == .systemDaemon
        if let error = outcome.secondStepError {
            if isApple || !enabled {
                // 设置已经记下了，但 SIP 等原因不能当场生效
                pendingReboot.insert(item.id)
            } else {
                // 第三方服务启用了，但没能启动起来，要告诉用户
                lastError = "已经启用，但没能马上启动。下次登录时系统会再试一次。\n\n"
                    + FriendlyError.text(error)
            }
        } else {
            pendingReboot.remove(item.id)
        }
        savePendingReboot()

        history.insert(ChangeRecord(date: Date(), label: item.label,
                                    scope: item.scope.rawValue, disabled: !enabled), at: 0)
        saveHistory()
        stateCache[item.id] = nil
        reload()
    }

    /// 立即重启电脑（走系统正常的重启流程，未保存的文档会提示保存）
    func restartNow() {
        DispatchQueue.global().async {
            Shell.run("/usr/bin/osascript", ["-e", "tell application \"loginwindow\" to «event aevtrrst»"])
        }
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
        guard !pending.isEmpty, !isWorking else { return }
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            var adminCommands: [[String]] = []
            for record in pending {
                guard let scope = ServiceItem.Scope(rawValue: record.scope) else { continue }
                let cmd = [Launchctl.path, "enable", "\(scope.domain)/\(record.label)"]
                if scope.needsAdmin { adminCommands.append(cmd) } else { Shell.run(cmd[0], Array(cmd.dropFirst())) }
            }
            let adminResult = adminCommands.isEmpty ? nil : Shell.runAsAdmin(adminCommands)
            DispatchQueue.main.async {
                self.isWorking = false
                if let r = adminResult, !r.ok {
                    self.lastError = "部分系统级服务没有恢复。\n\n" + FriendlyError.text(r.output)
                    self.reload()
                    return
                }
                for record in pending {
                    self.history.insert(ChangeRecord(date: Date(), label: record.label,
                                                     scope: record.scope, disabled: false), at: 0)
                    // 苹果系统服务恢复后也需要重启才完全生效，标记一下
                    if record.scope == ServiceItem.Scope.systemAgent.rawValue
                        || record.scope == ServiceItem.Scope.systemDaemon.rawValue {
                        self.pendingReboot.insert(record.scope + "/" + record.label)
                    }
                }
                self.saveHistory()
                self.savePendingReboot()
                self.reload()
            }
        }
    }

    // MARK: - 持久化

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL) else { return }
        history = (try? JSONDecoder().decode([ChangeRecord].self, from: data)) ?? []
    }

    private func saveHistory() {
        if history.count > historyLimit { history.removeLast(history.count - historyLimit) }
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    /// 读取上次保存的「重启后生效」标记；如果电脑已经重启过，就清掉
    private func loadPendingReboot() {
        guard let data = try? Data(contentsOf: pendingURL),
              let file = try? JSONDecoder().decode(PendingRebootFile.self, from: data) else { return }
        if file.bootTime == BootTime.current() {
            pendingReboot = Set(file.ids)
        } else {
            try? FileManager.default.removeItem(at: pendingURL)
        }
    }

    private func savePendingReboot() {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let file = PendingRebootFile(bootTime: BootTime.current(), ids: Array(pendingReboot))
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: pendingURL, options: .atomic)
        }
    }
}
