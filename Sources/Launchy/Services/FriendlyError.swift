import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 把 launchctl / osascript 的英文报错翻译成大白话
enum FriendlyError {
    static func text(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        let rules: [(keys: [String], text: String)] = [
            (["user canceled", "-128"], "你取消了输入密码，所以什么都没改。"),
            (["operation not permitted", "system integrity protection"], "系统不允许这样做（可能受 SIP 保护）。"),
            (["permission denied", "not privileged"], "没有权限。这一项需要管理员密码。"),
            (["could not find service", "no such process", "not found"], "找不到这个服务，它可能已经没在运行了。"),
            (["service is disabled"], "这个服务处于停用状态，请先把开关打开。"),
            (["already loaded", "already bootstrapped", "in progress"], "它已经在运行了。"),
            (["input/output error", "error: 5"], "系统拒绝了这个操作，常见原因是配置文件有问题，或者需要重启才能生效。"),
            (["invalid property list", "unexpected character", "encountered unknown tag"], "配置文件格式不对。"),
            (["no such file"], "找不到对应的文件，可能已经被删除或移动。")
        ]
        for rule in rules where rule.keys.contains(where: { lower.contains($0) }) {
            return s.isEmpty ? rule.text : "\(rule.text)\n\n详细信息：\(s)"
        }
        return s.isEmpty ? "出了点问题，但系统没有给出原因。" : "出了点问题：\(s)"
    }

    /// 上面拼「详细信息」时用的分隔
    static let detailMarker = "\n\n详细信息："

    /// 提示框里显示的文字：原始英文报错很长（多行或超过 160 个字）时先收起来，
    /// 只留大白话，并告诉用户可以「拷贝详情」；短的照常显示。完整原文仍由 report(_:) 拷贝。
    static func alertSummary(_ message: String) -> String {
        let hint = "（系统给的原始报错比较长，已经收起来了。需要发给别人看时，点「拷贝详情」。）"
        if let r = message.range(of: detailMarker) {
            let raw = message[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isLong(raw) else { return message }
            return String(message[..<r.lowerBound]) + "\n\n" + hint
        }
        guard message.count > 300 || message.split(separator: "\n").count > 8 else { return message }
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).prefix(6)
        var head = lines.joined(separator: "\n")
        if head.count > 200 { head = String(head.prefix(200)) }
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + "……\n\n" + hint
    }

    /// 只是用户自己取消了输入密码，没什么可拷贝的
    static func isUserCancel(_ message: String) -> Bool {
        message.hasPrefix("你取消了输入密码")
    }

    /// 点「拷贝详情」时放进剪贴板的整段文字：完整报错 + 软件和系统版本 + 时间，方便发给别人求助
    static func report(_ message: String, appVersion: String?, date: Date = Date()) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = ["启动台助手 Launchy 出错信息", ""]
        lines.append(message.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        lines.append("软件版本：\(appVersion ?? "未知")")
        lines.append("macOS：\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        lines.append("时间：\(formatter.string(from: date))")
        return lines.joined(separator: "\n")
    }

    private static func isLong(_ raw: String) -> Bool {
        raw.count > 160 || raw.split(separator: "\n").count > 2
    }
}

/// 开机时间，用来判断「重启后生效」的标记是否已经过期
enum BootTime {
    static func current() -> Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return Int(tv.tv_sec)
    }
}
