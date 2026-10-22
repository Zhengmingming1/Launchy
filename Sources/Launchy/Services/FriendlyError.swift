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
