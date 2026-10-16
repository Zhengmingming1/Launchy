import Foundation
import AppKit

/// 从 plist 里读出来、给详情页用的完整信息
struct ServiceInfo {
    let item: ServiceItem
    let dict: [String: Any]

    init(item: ServiceItem) {
        self.item = item
        self.dict = PlistIO.read(item.plistURL) ?? [:]
    }

    var program: String? {
        (dict["Program"] as? String) ?? arguments.first
    }
    var arguments: [String] { dict["ProgramArguments"] as? [String] ?? [] }
    var runAtLoad: Bool { dict["RunAtLoad"] as? Bool ?? false }
    var startInterval: Int? { dict["StartInterval"] as? Int }
    var watchPaths: [String] { dict["WatchPaths"] as? [String] ?? [] }

    /// 是否可编辑：用户自己目录和 /Library 下的可以，苹果的只读
    var editable: Bool { item.scope == .user || item.scope == .allUsers || item.scope == .daemon }

    // MARK: - 所属程序

    /// 优先从程序路径里找 .app；再试 AssociatedBundleIdentifiers / 标签对应的 bundle id
    var owningAppURL: URL? {
        if let program, let range = program.range(of: ".app/") {
            return URL(fileURLWithPath: String(program[..<range.lowerBound]) + ".app")
        }
        var ids: [String] = []
        if let s = dict["AssociatedBundleIdentifiers"] as? String { ids.append(s) }
        if let a = dict["AssociatedBundleIdentifiers"] as? [String] { ids += a }
        // 例如 com.tencent.Lemon.monitor -> com.tencent.Lemon
        let parts = item.label.split(separator: ".")
        if parts.count > 3 { ids.append(parts.dropLast().joined(separator: ".")) }
        ids.append(item.label)
        for id in ids {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    var owningAppName: String? {
        owningAppURL.map { $0.deletingPathExtension().lastPathComponent }
    }

    // MARK: - 什么时候运行

    var whenText: String {
        var parts: [String] = []
        if runAtLoad { parts.append("开机登录时启动") }
        if let keep = dict["KeepAlive"] {
            if (keep as? Bool) == true { parts.append("一直在后台运行，退出后会被自动拉起") }
            else if keep is [String: Any] { parts.append("满足特定条件时保持运行") }
        }
        if let s = startInterval { parts.append("每隔 \(humanSeconds(s)) 运行一次") }
        if let cal = dict["StartCalendarInterval"] {
            let list = (cal as? [[String: Any]]) ?? ((cal as? [String: Any]).map { [$0] } ?? [])
            for c in list { parts.append(calendarText(c)) }
        }
        if !watchPaths.isEmpty { parts.append("这些文件变化时运行：\(watchPaths.joined(separator: "、"))") }
        if dict["MachServices"] != nil && parts.isEmpty { parts.append("被其他程序调用时才启动") }
        if dict["LaunchEvents"] != nil { parts.append("特定系统事件发生时运行") }
        return parts.isEmpty ? "按需启动（没有固定时间）" : parts.joined(separator: "；")
    }

    private func humanSeconds(_ s: Int) -> String {
        if s % 86400 == 0 { return "\(s / 86400) 天" }
        if s % 3600 == 0 { return "\(s / 3600) 小时" }
        if s % 60 == 0 { return "\(s / 60) 分钟" }
        return "\(s) 秒"
    }

    private func calendarText(_ c: [String: Any]) -> String {
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        var t = ""
        if let d = c["Day"] as? Int { t += "每月 \(d) 号 " }
        if let w = c["Weekday"] as? Int, w >= 0, w < weekdays.count { t += "每\(weekdays[w]) " }
        if t.isEmpty { t = "每天 " }
        let h = c["Hour"] as? Int, m = c["Minute"] as? Int
        if let h { t += String(format: "%02d:%02d", h, m ?? 0) }
        else if let m { t += "每小时第 \(m) 分" }
        return t.trimmingCharacters(in: .whitespaces) + " 运行"
    }

    // MARK: - 它是做什么的

    var description: String {
        if let known = FriendlyNames.describe(item.label) { return known }
        return FriendlyNames.guess(label: item.label, program: program, appName: owningAppName)
    }
}
