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

    static func tail(of url: URL, bytes: Int = tailBytes) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 认出来的问题：给人看的一句话，出错的那一行，以及可以立刻做的下一步
    struct Problem: Equatable {
        let hint: String
        let line: String
        /// 可以立刻做的下一步；认不出对应动作时为 nil
        var fix: Fix? = nil

        /// 运行记录窗口橙色说明旁的按钮
        enum Fix: Equatable {
            /// 被隐私保护拦住：打开「完全磁盘访问权限」
            case openFullDiskAccess
            /// 任务要打开或运行的文件找不到了：重新选择
            case rechoose

            var title: String {
                switch self {
                case .openFullDiskAccess: return "打开系统设置"
                case .rechoose: return "重新选择…"
                }
            }
        }
    }

    /// 从最后一行往前找，找到第一条认识的错误就返回
    static func diagnose(log: String, action: TaskAction) -> String? {
        problem(in: log, action: action)?.hint
    }

    /// 和 diagnose 一样，但同时返回出错的那一行，运行记录窗口用它来标橙、滚动过去
    static func problem(in log: String, action: TaskAction) -> Problem? {
        let lines = log.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(tailLines)
        for line in lines.reversed() {
            if let found = classify(line, action: action) {
                return Problem(hint: found.hint, line: line, fix: found.fix)
            }
        }
        return nil
    }

    private struct Classified {
        let hint: String
        var fix: Problem.Fix? = nil
    }

    private static func classify(_ line: String, action: TaskAction) -> Classified? {
        // zsh：「脚本路径:行号: command not found: 命令」或「zsh: command not found: 命令」
        if let m = match(line, #"^(?:(.+?):(\d+)|zsh): command not found: (\S+)"#) {
            let cmd = m[2]
            let place = m[1].isEmpty ? "脚本里" : "脚本第 \(m[1]) 行"
            if let full = installedPath(of: cmd) {
                return Classified(hint: "\(place)的命令「\(cmd)」找不到。定时运行时系统不会自动去 \(dir(of: full)) 里找，把它改成完整路径 \(full) 就行")
            }
            return Classified(hint: "\(place)的命令「\(cmd)」找不到，可能还没安装，或者名字拼错了")
        }
        // zsh：「…: permission denied: 路径」
        if let m = match(line, #"(?:^|:\d+: |zsh: )permission denied: (.+)$"#) {
            return Classified(hint: "没有权限打开「\(name(of: m[0]))」，可以在访达里「显示简介」检查它的权限")
        }
        // zsh / cd：「…: no such file or directory: 路径」
        if let m = match(line, #"no such file or directory: (.+)$"#) {
            // 只在找不到的是这个任务自己的文件时给「重新选择」，脚本里提到的其他路径不算
            return Classified(
                hint: "找不到「\(name(of: m[0]))」，它可能被移走、改名或删除了",
                fix: isTaskTarget(m[0], action: action) ? .rechoose : nil
            )
        }
        // macOS 隐私保护拦住了（访问桌面、文稿、下载等文件夹时常见）
        if line.range(of: "Operation not permitted", options: .caseInsensitive) != nil {
            return Classified(
                hint: "被 macOS 的隐私保护拦住了：到「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里允许 /bin/zsh 后再试",
                fix: .openFullDiskAccess
            )
        }
        // open -a：找不到程序
        if let m = match(line, #"Unable to find application named '(.+)'"#) {
            return Classified(
                hint: "找不到程序「\(m[0])」，可能已经卸载或改名，重新选一下就好",
                fix: action.kind == .openApp ? .rechoose : nil
            )
        }
        // open：文件不存在
        if let m = match(line, #"The file (.+) does not exist\."#) {
            return Classified(
                hint: "找不到「\(name(of: m[0]))」，它可能被移走、改名或删除了",
                fix: (action.kind == .openFile || isTaskTarget(m[0], action: action)) ? .rechoose : nil
            )
        }
        return nil
    }

    /// 日志里提到的路径是不是这个任务要打开 / 运行的那个文件
    private static func isTaskTarget(_ reported: String, action: TaskAction) -> Bool {
        let reported = reported.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        guard !reported.isEmpty, !action.path.isEmpty else { return false }
        let a = URL(fileURLWithPath: reported).standardizedFileURL.path
        let b = URL(fileURLWithPath: action.path).standardizedFileURL.path
        if a == b { return true }
        // 有的日志只写出文件名
        if !reported.contains("/") {
            let name = URL(fileURLWithPath: b).lastPathComponent
            let stem = URL(fileURLWithPath: b).deletingPathExtension().lastPathComponent
            return name == reported || stem == reported
        }
        return false
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
