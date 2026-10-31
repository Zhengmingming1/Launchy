import Foundation

/// 「怎么修」第二步：任务运行失败时，读运行记录的最后几行，
/// 认出常见错误后用大白话说清楚是哪条命令、哪个文件出了问题。
/// 只读日志，不改任何东西；认不出来就返回 nil，界面退回按退出码解释。
enum LogDiagnosis {
    /// 只看日志末尾这么多字节，日志再大也不会拖慢扫描
    static let tailBytes = 4096
    /// 只看最后这么多行，免得把很久以前的错误当成这次的
    static let tailLines = 20

    /// 读取日志文件末尾并给出诊断
    static func diagnose(logURL: URL, action: TaskAction) -> String? {
        guard let text = tail(of: logURL) else { return nil }
        return diagnose(log: text, action: action)
    }

    static func tail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 从最后一行往前找，找到第一条认识的错误就返回
    static func diagnose(log: String, action: TaskAction) -> String? {
        let lines = log.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(tailLines)
        for line in lines.reversed() {
            if let hint = hint(for: line, action: action) { return hint }
        }
        return nil
    }

    private static func hint(for line: String, action: TaskAction) -> String? {
        // zsh：「脚本路径:行号: command not found: 命令」或「zsh: command not found: 命令」
        if let m = match(line, #"^(?:(.+?):(\d+)|zsh): command not found: (\S+)"#) {
            let cmd = m[2]
            let place = m[1].isEmpty ? "脚本里" : "脚本第 \(m[1]) 行"
            if let full = installedPath(of: cmd) {
                return "\(place)的命令「\(cmd)」找不到。定时运行时系统不会自动去 \(dir(of: full)) 里找，把它改成完整路径 \(full) 就行"
            }
            return "\(place)的命令「\(cmd)」找不到，可能还没安装，或者名字拼错了"
        }
        // zsh：「…: permission denied: 路径」
        if let m = match(line, #"(?:^|:\d+: |zsh: )permission denied: (.+)$"#) {
            return "没有权限打开「\(name(of: m[0]))」，可以在访达里「显示简介」检查它的权限"
        }
        // zsh / cd：「…: no such file or directory: 路径」
        if let m = match(line, #"no such file or directory: (.+)$"#) {
            return "找不到「\(name(of: m[0]))」，它可能被移走、改名或删除了"
        }
        // macOS 隐私保护拦住了（访问桌面、文稿、下载等文件夹时常见）
        if line.range(of: "Operation not permitted", options: .caseInsensitive) != nil {
            return "被 macOS 的隐私保护拦住了：到「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里允许 /bin/zsh 后再试"
        }
        // open -a：找不到程序
        if let m = match(line, #"Unable to find application named '(.+)'"#) {
            return "找不到程序「\(m[0])」，可能已经卸载或改名，重新选一下就好"
        }
        // open：文件不存在
        if let m = match(line, #"The file (.+) does not exist\."#) {
            return "找不到「\(name(of: m[0]))」，它可能被移走、改名或删除了"
        }
        return nil
    }

    /// Homebrew 等常见位置里有没有这个命令（launchd 默认的 PATH 不包含它们）
    static func installedPath(of command: String) -> String? {
        guard !command.contains("/") else { return nil }
        let dirs = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
                    Paths.home.appendingPathComponent(".local/bin").path]
        return dirs.map { "\($0)/\(command)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func dir(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    private static func name(of path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        let last = URL(fileURLWithPath: trimmed).lastPathComponent
        return last.isEmpty ? trimmed : last
    }

    /// 返回各捕获组（没匹配到的组为空字符串）
    private static func match(_ line: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let r = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<r.numberOfRanges).map { i in
            Range(r.range(at: i), in: line).map { String(line[$0]) } ?? ""
        }
    }
}
