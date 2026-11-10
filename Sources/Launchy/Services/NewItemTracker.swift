import Foundation

/// 记住每个第三方自启动项「第一次被 Launchy 看到」的时间，用来标出最近新冒出来的自启动项。
///
/// - 第一次使用（还没有记录文件）时，把现有的全部当作「早就有的」，不会一打开就满屏「新增」。
/// - 之后每次扫描到没见过的项，记下当前时间；7 天内都标为「最近新增」。
/// - 用户点「知道了」后不再标记。
/// - 只记录第三方自启动项；苹果系统服务不参与。只读扫描结果，不改任何系统文件。
struct NewItemTracker {
    /// 多久以内出现的算「最近新增」
    static let window: TimeInterval = 7 * 24 * 3600

    private struct File: Codable {
        var firstSeen: [String: Date]
    }

    private let url = Paths.support.appendingPathComponent("seen-startup-items.json")
    /// nil 表示还没有记录文件（第一次使用）
    private var firstSeen: [String: Date]?

    init() {
        if let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(File.self, from: data) {
            firstSeen = file.firstSeen
        }
    }

    /// 根据这次扫描结果更新记录，返回每个「最近新增」项的出现时间（key 是 ServiceItem.id）
    mutating func update(with items: [ServiceItem], now: Date = Date()) -> [String: Date] {
        let ids = Set(items.map(\.id))
        var map: [String: Date]
        if let existing = firstSeen {
            map = existing
            for id in ids where map[id] == nil { map[id] = now }
            // 暂时扫不到的项也继续记着：万一某次扫描读不到某个文件夹，
            // 下次不会把老项目误标成「新增」。记录只有标签，很小。
        } else {
            // 第一次：现有的都算「早就有的」
            map = Dictionary(uniqueKeysWithValues: ids.map { ($0, Date.distantPast) })
        }
        if map != firstSeen {
            firstSeen = map
            save()
        }
        return map.filter { ids.contains($0.key) && now.timeIntervalSince($0.value) < Self.window }
    }

    /// 用户看过了，不再标为新增
    mutating func acknowledge(_ id: String) {
        guard firstSeen?[id] != nil else { return }
        firstSeen?[id] = .distantPast
        save()
    }

    /// 一次确认好几个（装一套软件常常同时加好几个自启动项），只写一次文件
    mutating func acknowledge(_ ids: [String]) {
        var changed = false
        for id in ids where firstSeen?[id] != nil {
            firstSeen?[id] = .distantPast
            changed = true
        }
        if changed { save() }
    }

    private func save() {
        guard let firstSeen else { return }
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(File(firstSeen: firstSeen)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 「今天 14:02」「昨天 09:30」「11月3日」
    static func describe(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = String(format: "%02d:%02d", cal.component(.hour, from: date), cal.component(.minute, from: date))
        if cal.isDate(date, inSameDayAs: now) { return "今天 \(time)" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "昨天 \(time)" }
        return "\(cal.component(.month, from: date))月\(cal.component(.day, from: date))日"
    }
}
