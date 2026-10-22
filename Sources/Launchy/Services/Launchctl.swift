import Foundation

/// 对 launchctl 命令的简单封装。
enum Launchctl {
    static let path = "/bin/launchctl"

    /// 当前用户的图形会话域，例如 gui/501
    static var userDomain: String { "gui/\(getuid())" }
    static let systemDomain = "system"

    // MARK: - 加载 / 卸载

    @discardableResult
    static func bootstrap(domain: String = userDomain, plist: URL) -> Shell.Result {
        Shell.run(path, ["bootstrap", domain, plist.path])
    }

    @discardableResult
    static func bootout(domain: String = userDomain, label: String) -> Shell.Result {
        Shell.run(path, ["bootout", "\(domain)/\(label)"])
    }

    // MARK: - 启用 / 停用（会被系统记住，重启后依然有效）

    @discardableResult
    static func enable(domain: String = userDomain, label: String) -> Shell.Result {
        Shell.run(path, ["enable", "\(domain)/\(label)"])
    }

    @discardableResult
    static func disable(domain: String = userDomain, label: String) -> Shell.Result {
        Shell.run(path, ["disable", "\(domain)/\(label)"])
    }

    // MARK: - 状态查询

    struct RunInfo {
        let pid: Int?
        let lastExitStatus: Int?
    }

    /// 解析 `launchctl list` 的输出，得到当前用户已加载的任务。
    /// 每行格式：PID  Status  Label，PID 为 "-" 表示没在运行。
    static func loadedJobs() -> [String: RunInfo] {
        let result = Shell.run(path, ["list"])
        var map: [String: RunInfo] = [:]
        for line in result.output.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { continue }
            map[String(cols[2])] = RunInfo(pid: Int(cols[0]), lastExitStatus: Int(cols[1]))
        }
        return map
    }

    /// 解析 `launchctl print-disabled <domain>`，得到「覆盖设置」：标签 -> 是否停用。
    /// 这是 launchd 实际采用的开关状态，优先级高于 plist 里的 Disabled 字段。
    /// 不同系统版本输出可能是 `=> disabled/enabled` 或 `=> true/false`，都兼容。
    static func overrides(domain: String = userDomain) -> [String: Bool] {
        let result = Shell.run(path, ["print-disabled", domain])
        var map: [String: Bool] = [:]
        for raw in result.output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\""), let arrow = line.range(of: "=>") else { continue }
            let label = line[..<arrow.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("disabled") || value.hasPrefix("true") { map[label] = true }
            else if value.hasPrefix("enabled") || value.hasPrefix("false") { map[label] = false }
        }
        return map
    }

    /// 被停用的标签集合（只看覆盖设置）
    static func disabledLabels(domain: String = userDomain) -> Set<String> {
        Set(overrides(domain: domain).filter { $0.value }.keys)
    }
}

// MARK: - 单个服务的详细状态

extension Launchctl {
    struct ServiceState {
        let loaded: Bool
        let running: Bool
        let pid: Int?
        var lastExitCode: String? = nil
    }

    /// 用 `launchctl print <domain>/<label>` 查询状态。
    /// 输出里有类似 `state = running`、`pid = 123` 的行；命令失败说明没加载。
    static func state(domain: String, label: String) -> ServiceState {
        let r = Shell.run(path, ["print", "\(domain)/\(label)"])
        guard r.ok else { return ServiceState(loaded: false, running: false, pid: nil) }
        var pid: Int?
        var running = false
        var lastExit: String?
        for raw in r.output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // 只看第一层的字段，避免读到嵌套块里的同名字段
            if pid == nil, line.hasPrefix("pid = ") {
                pid = Int(line.dropFirst("pid = ".count))
            } else if lastExit == nil, line.hasPrefix("last exit code = ") {
                lastExit = String(line.dropFirst("last exit code = ".count))
            } else if line.hasPrefix("state = ") {
                running = running || line.hasSuffix("running")
            }
        }
        return ServiceState(loaded: true, running: running || pid != nil, pid: pid, lastExitCode: lastExit)
    }

    /// 一次性读取整个域的服务列表：`launchctl print system` 或 `print gui/<uid>`。
    /// 输出里有一段
    ///     services = {
    ///         123      0     com.foo.bar
    ///           0      -     com.foo.baz
    ///     }
    /// 第一列是进程号（0 表示没运行），第二列是上次退出码，最后一列是标签。
    /// 返回 nil 表示没解析到（比如系统改了输出格式），调用方需要退回逐个查询。
    static func domainSnapshot(_ domain: String) -> [String: ServiceState]? {
        let r = Shell.run(path, ["print", domain])
        guard r.ok else { return nil }
        var map: [String: ServiceState] = [:]
        var inServices = false
        for raw in r.output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !inServices {
                if line.hasPrefix("services = {") { inServices = true }
                continue
            }
            if line.hasPrefix("}") { break }
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 3, let pidValue = Int(cols[0]) else { continue }
            let label = String(cols[cols.count - 1])
            let pid = pidValue > 0 ? pidValue : nil
            let exit = String(cols[1])
            map[label] = ServiceState(loaded: true, running: pid != nil, pid: pid,
                                      lastExitCode: exit == "-" ? nil : exit)
        }
        return map.isEmpty ? nil : map
    }

    /// 批量查询状态：每个域只调用一次 launchctl print；
    /// 只有某个域解析失败时，才退回逐个 `launchctl print`，并且最多同时跑 8 个。
    static func states(_ items: [(domain: String, label: String)]) -> [ServiceState] {
        var snapshots: [String: [String: ServiceState]?] = [:]
        for domain in Set(items.map(\.domain)) { snapshots[domain] = domainSnapshot(domain) }

        var results = [ServiceState?](repeating: nil, count: items.count)
        var fallback: [Int] = []
        for (i, item) in items.enumerated() {
            if let snapshot = snapshots[item.domain] ?? nil {
                results[i] = snapshot[item.label] ?? ServiceState(loaded: false, running: false, pid: nil)
            } else {
                fallback.append(i)
            }
        }

        if !fallback.isEmpty {
            let lock = NSLock()
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 8
            for i in fallback {
                queue.addOperation {
                    let s = state(domain: items[i].domain, label: items[i].label)
                    lock.lock(); results[i] = s; lock.unlock()
                }
            }
            queue.waitUntilAllOperationsAreFinished()
        }
        return results.map { $0 ?? ServiceState(loaded: false, running: false, pid: nil) }
    }

    /// 某个服务现在是否已加载
    static func isLoaded(domain: String, label: String) -> Bool {
        Shell.run(path, ["print", "\(domain)/\(label)"]).ok
    }
}
