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

    /// 解析 `launchctl print-disabled <domain>`，返回被停用的标签集合。
    /// 不同系统版本输出可能是 `=> disabled` 或 `=> true`，两种都兼容。
    static func disabledLabels(domain: String = userDomain) -> Set<String> {
        let result = Shell.run(path, ["print-disabled", domain])
        var set = Set<String>()
        for raw in result.output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\""), let arrow = line.range(of: "=>") else { continue }
            let label = line[..<arrow.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("disabled") || value.hasPrefix("true") {
                set.insert(label)
            }
        }
        return set
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

    /// 并发批量查询，几百个服务也只要一两秒
    static func states(_ items: [(domain: String, label: String)]) -> [ServiceState] {
        var results = [ServiceState?](repeating: nil, count: items.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: items.count) { i in
            let s = state(domain: items[i].domain, label: items[i].label)
            lock.lock(); results[i] = s; lock.unlock()
        }
        return results.map { $0 ?? ServiceState(loaded: false, running: false, pid: nil) }
    }
}
