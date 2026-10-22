import Foundation

/// 运行命令行程序的小工具。
enum Shell {
    struct Result {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    /// 同步执行一个程序，返回退出码和输出（stdout + stderr）。
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        // 先读完输出再等待，避免输出过多时管道被塞满卡死
        let handle = pipe.fileHandleForReading
        let data = handle.readDataToEndOfFile()
        try? handle.close()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      output: String(decoding: data, as: UTF8.self))
    }

    /// 以管理员身份执行一串 shell 命令（会弹出系统的密码框）。
    /// 原理：osascript 的 `do shell script ... with administrator privileges`。
    @discardableResult
    static func runAsAdmin(_ commands: [[String]]) -> Result {
        let line = commands
            .map { $0.map(shellQuote).joined(separator: " ") }
            .joined(separator: " ; ")
        // AppleScript 字符串里需要转义反斜杠和双引号
        let escaped = line
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", script])
    }

    /// 给 shell 参数加单引号，防止空格和特殊字符出问题。
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension Shell {
    /// 以管理员身份执行一整段 shell 脚本（只弹一次密码框）。
    @discardableResult
    static func runAsAdmin(script: String) -> Result {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }
}
