import Foundation
import AppKit

/// 管理「我的任务」：增删改查 + 暂停/恢复。
@MainActor
final class MyTasksStore: ObservableObject {
    @Published private(set) var tasks: [MyTask] = []
    @Published var lastError: String?

    private var scanGeneration = 0
    /// 监听 ~/Library/LaunchAgents：在访达里删掉、或用别的工具改了任务文件时，列表自动跟着变
    private var watcher: DirectoryWatcher?
    private var activationObserver: NSObjectProtocol?
    private var lastActivationReload = Date.distantPast
    /// 切回 Launchy 时最多每 3 秒刷新一次，来回切窗口不会反复扫描
    private let activationThrottle: TimeInterval = 3

    init() {
        reload()
        watcher = DirectoryWatcher([Paths.userAgents]) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watcher?.start()
        // 任务在后台跑完后，「上次运行成功 / 失败」不会自己变；用户切回 Launchy 时顺手刷新一下，
        // 看到的就是最新结果，不用再去点「刷新」
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadOnActivation() }
        }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    private func reloadOnActivation() {
        guard Date().timeIntervalSince(lastActivationReload) >= activationThrottle else { return }
        lastActivationReload = Date()
        reload()
    }

    /// 重新扫描 ~/Library/LaunchAgents 里 com.launchy.* 的文件，并刷新运行状态（在后台执行）
    func reload() {
        scanGeneration += 1
        let generation = scanGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let tasks = Self.scan()
            DispatchQueue.main.async {
                // 期间又触发了新的扫描（例如保存后目录变化又刷新一次），丢掉旧结果，免得列表闪回旧状态
                guard generation == self.scanGeneration else { return }
                // 内容没变就不重新赋值，避免列表无谓重绘
                if self.tasks != tasks { self.tasks = tasks }
                // ~/Library/LaunchAgents 一开始不存在时，第一次建好任务后补上监听
                self.watcher?.start()
            }
        }
    }

    nonisolated private static func scan() -> [MyTask] {
        let loaded = Launchctl.loadedJobs()
        let disabled = Launchctl.disabledLabels()
        return PlistIO.plists(in: Paths.userAgents)
            .filter { $0.lastPathComponent.hasPrefix(MyTask.labelPrefix) }
            .compactMap { url -> MyTask? in
                guard let dict = PlistIO.read(url), var task = MyTask(plist: dict) else { return nil }
                task.isLoaded = loaded[task.label] != nil
                task.lastExitStatus = loaded[task.label]?.lastExitStatus
                task.isPaused = disabled.contains(task.label) || !task.isLoaded
                // 和残留项检查同一套规则：只有系统明确说「没有这个文件」才算丢了
                task.targetMissing = ServiceItem.isProgramMissing(task.action.path)
                if task.isLoaded {
                    // 运行次数只有 `launchctl print <域>/<标签>` 才有；我的任务通常很少，逐个查不慢
                    task.runCount = Launchctl.state(domain: Launchctl.userDomain, label: task.label).runs
                }
                return task
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// 新建或保存任务。保存后立即生效（除非任务是暂停状态）。
    func save(_ task: MyTask) {
        do {
            try FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
            // 先卸载旧版本，否则 launchd 不会读到新配置
            Launchctl.bootout(label: task.label)
            try PlistIO.write(task.toPlist(), to: task.plistURL)
            if !task.isPaused {
                Launchctl.enable(label: task.label)
                let r = Launchctl.bootstrap(plist: task.plistURL)
                if !r.ok { lastError = "任务已保存，但没能启动。\n\n" + FriendlyError.text(r.output) }
            }
        } catch {
            lastError = "保存失败：\(error.localizedDescription)"
        }
        reload()
    }

    /// 删除任务：卸载、删掉 plist 和日志
    func delete(_ task: MyTask) {
        Launchctl.bootout(label: task.label)
        Launchctl.enable(label: task.label) // 清掉 disabled 记录，免得留垃圾
        try? FileManager.default.removeItem(at: task.plistURL)
        try? FileManager.default.removeItem(at: task.logURL)
        reload()
    }

    /// 暂停 = 卸载 + 标记停用（下次登录也不会自动加载）；恢复 = 反过来
    func setPaused(_ task: MyTask, _ paused: Bool) {
        if paused {
            Launchctl.bootout(label: task.label)
            Launchctl.disable(label: task.label)
        } else {
            Launchctl.enable(label: task.label)
            let r = Launchctl.bootstrap(plist: task.plistURL)
            if !r.ok { lastError = "没能恢复这个任务。\n\n" + FriendlyError.text(r.output) }
        }
        reload()
    }

    /// 立刻执行一次，方便测试
    func runNow(_ task: MyTask) {
        if !task.isLoaded { Launchctl.bootstrap(plist: task.plistURL) }
        Shell.run(Launchctl.path, ["kickstart", "\(Launchctl.userDomain)/\(task.label)"])
        reload()
    }

    /// 读取日志的最后几千个字符
    func log(for task: MyTask) -> String {
        guard let text = try? String(contentsOf: task.logURL, encoding: .utf8), !text.isEmpty else {
            return "还没有输出。任务运行后，这里会显示它打印的内容和错误信息。"
        }
        return String(text.suffix(6000))
    }
}
