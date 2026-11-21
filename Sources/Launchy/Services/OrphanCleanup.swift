import AppKit
import Foundation

extension ServiceEditor {
    /// 清理一批残留自启动项的结果（先备份再移到废纸篓）
    struct CleanResult: Sendable {
        struct Item: Sendable {
            let id: String
            let name: String
            /// 移到废纸篓之后的实际位置；没拿到或不在了就是 nil
            let trashURL: URL?
        }
        struct Failure: Sendable {
            let id: String
            let name: String
            let reason: String
        }

        var trashed: [Item] = []
        var failures: [Failure] = []
        /// 用户在管理员密码框里点了取消，剩下的项没有继续处理
        var cancelled = false

        /// 给用户看的整段说明，没有变化时为空
        var userMessage: String {
            if cancelled && trashed.isEmpty {
                return "你取消了输入密码，没有清理任何项。"
            }
            var parts: [String] = []
            if trashed.count == 1 {
                parts.append("已把「\(trashed[0].name)」的残留配置移到废纸篓。")
            } else if trashed.count > 1 {
                parts.append("已把 \(trashed.count) 个残留配置移到废纸篓。")
            }
            if !revealableURLs.isEmpty {
                if revealableURLs.count == 1 {
                    parts.append("访达已经打开并选中了这个文件，需要的话可以把它拖回去。")
                } else {
                    parts.append("访达已经打开并选中了这些文件，需要的话可以把它们拖回去。")
                }
            }
            if cancelled {
                parts.append("你取消了输入密码，剩下的没有继续清理。")
            }
            if !failures.isEmpty {
                let details = failures.map { "「\($0.name)」\($0.reason)" }.joined(separator: "；")
                if trashed.isEmpty && !cancelled {
                    parts.append("这些残留配置没能移到废纸篓：\(details)。")
                } else {
                    parts.append("另外：\(details)。")
                }
            }
            return parts.joined(separator: "")
        }

        /// 废纸篓里现在还在、可以在访达中选中的文件
        var revealableURLs: [URL] {
            trashed.compactMap { item in
                guard let url = item.trashURL else { return nil }
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        }

        /// 用访达打开废纸篓并选中这些文件。没有可显示的文件时什么也不做。
        func revealTrashedInFinder() {
            let urls = revealableURLs
            guard !urls.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// 确认框标题
    static func cleanConfirmTitle(for items: [ServiceItem]) -> String {
        if items.count == 1 {
            return "确定把「\(items[0].friendlyName)」的残留配置移到废纸篓吗？"
        }
        return "确定把这 \(items.count) 个残留配置移到废纸篓吗？"
    }

    /// 确认框正文：先备份、能从废纸篓找回来；涉及 /Library 时提醒可能要一次密码
    static func cleanConfirmMessage(for items: [ServiceItem]) -> String {
        var parts: [String] = []
        if items.count > 1 {
            parts.append("包括：" + items.map(\.friendlyName).joined(separator: "、") + "。")
        }
        parts.append("会先备份一份，之后可以在废纸篓里找回来，也可以在本软件里从备份还原。不会永久删除，也不会动其他自启动项。")
        if items.contains(where: needsAdminToTrash) {
            if items.count == 1, items[0].scope == .allUsers {
                parts.append("这一项对所有用户生效，可能要输入一次登录密码。")
            } else if items.count == 1 {
                parts.append("这是系统级的项，可能要输入一次登录密码。")
            } else {
                parts.append("其中「所有用户」或系统级的项可能要输入一次登录密码。")
            }
        }
        return parts.joined(separator: "")
    }

    /// /Library 下的配置需要管理员权限才能移到废纸篓（和 launchctl 是否要密码不是一回事）
    static func needsAdminToTrash(_ item: ServiceItem) -> Bool {
        item.scope == .allUsers || item.scope == .daemon
    }

    /// 当场重新检查、先备份，再卸载并移到废纸篓。不信任传入时的列表状态。
    /// 用户自己目录的项直接处理；/Library 下的项合并成一次密码框。
    static func cleanOrphans(_ items: [ServiceItem]) -> CleanResult {
        var result = CleanResult()
        var backedUp: [ServiceItem] = []
        for item in items {
            if let failure = prepareForClean(item) {
                result.failures.append(failure)
            } else {
                backedUp.append(item)
            }
        }

        let userItems = backedUp.filter { $0.scope == .user }
        let adminItems = backedUp.filter { needsAdminToTrash($0) }

        for item in userItems {
            var trashURL: URL?
            if let failure = trashUserOrphan(item, trashURL: &trashURL) {
                result.failures.append(failure)
            } else {
                result.trashed.append(.init(id: item.id, name: item.friendlyName, trashURL: trashURL))
            }
        }

        if !adminItems.isEmpty {
            cleanAdminOrphans(adminItems, into: &result)
        }
        return result
    }

    // MARK: - 安全检查 + 备份

    /// 返回失败原因；nil 表示已经备份成功，可以继续卸载和移到废纸篓
    private static func prepareForClean(_ item: ServiceItem) -> CleanResult.Failure? {
        let name = item.friendlyName
        func fail(_ reason: String) -> CleanResult.Failure {
            .init(id: item.id, name: name, reason: reason)
        }

        switch item.scope {
        case .user, .allUsers, .daemon: break
        case .systemAgent, .systemDaemon:
            return fail("是苹果的系统服务，不能清理。")
        }
        if item.label.hasPrefix(MyTask.labelPrefix) {
            return fail("是启动台助手自己的任务，请到「我的任务」里管理。")
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.plistURL.path, isDirectory: &isDir), !isDir.boolValue else {
            return fail("的配置文件已经不在了。")
        }
        guard let dict = PlistIO.read(item.plistURL) else {
            return fail("的配置没能读出来，没有移走。")
        }
        if let label = dict["Label"] as? String, label != item.label {
            return fail("的配置已经变了，没有移走。")
        }
        if dict["Label"] == nil {
            return fail("的配置已经变了，没有移走。")
        }

        let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
        // 没权限读取程序时当作还在，宁可漏掉也不误删
        guard ServiceItem.isProgramMissing(program) else {
            return fail("指向的程序现在还在，没有移走。")
        }

        do {
            try backup(item, reason: "orphan-cleanup")
        } catch {
            return fail("没能备份，所以没有移到废纸篓。")
        }
        return nil
    }

    // MARK: - 当前用户目录

    /// 备份之后：先卸载（本来就没加载也没关系），清掉停用记录，再移到废纸篓
    private static func trashUserOrphan(_ item: ServiceItem, trashURL: inout URL?) -> CleanResult.Failure? {
        Launchctl.bootout(domain: item.scope.domain, label: item.label)
        Launchctl.enable(domain: item.scope.domain, label: item.label)
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: item.plistURL, resultingItemURL: &resulting)
            trashURL = resulting as URL?
            return nil
        } catch {
            return .init(id: item.id, name: item.friendlyName,
                         reason: "移到废纸篓时出了点问题（\(FriendlyError.text(error.localizedDescription))）。")
        }
    }

    // MARK: - /Library 下的项（一次密码框）

    private static func cleanAdminOrphans(_ items: [ServiceItem], into result: inout CleanResult) {
        guard let trash = userTrashDirectory() else {
            for item in items {
                result.failures.append(.init(id: item.id, name: item.friendlyName,
                                             reason: "没能找到废纸篓的位置，所以没有移走。"))
            }
            return
        }
        try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

        var reserved = Set<String>()
        var destinations: [String: URL] = [:]
        var script = "ok=0"
        let q = Shell.shellQuote
        let lc = q(Launchctl.path)
        let owner = "\(getuid()):\(getgid())"

        for item in items {
            let dest = uniqueURL(in: trash, matching: item.plistURL, reserved: &reserved)
            destinations[item.id] = dest
            if item.scope == .daemon {
                let target = "\(item.scope.domain)/\(item.label)"
                script += " ; { \(lc) bootout \(q(target)) 2>/dev/null; true; }"
                script += " ; { \(lc) enable \(q(target)) 2>/dev/null; true; }"
            }
            script += " ; /bin/mv -n \(q(item.plistURL.path)) \(q(dest.path)) && /usr/sbin/chown \(owner) \(q(dest.path)) || ok=1"
        }
        script += " ; exit $ok"

        let r = Shell.runAsAdmin(script: script)
        if isAdminCancelled(r) {
            result.cancelled = true
            return
        }

        for item in items {
            let sourceGone = !FileManager.default.fileExists(atPath: item.plistURL.path)
            if sourceGone {
                let dest = destinations[item.id]
                let kept = dest.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                result.trashed.append(.init(id: item.id, name: item.friendlyName, trashURL: kept))
                // 「所有用户」的项属于当前登录会话，卸载不用管理员
                if item.scope == .allUsers {
                    Launchctl.bootout(domain: item.scope.domain, label: item.label)
                    Launchctl.enable(domain: item.scope.domain, label: item.label)
                }
            } else {
                let detail = r.ok ? "移到废纸篓时出了点问题。" : FriendlyError.text(r.output)
                result.failures.append(.init(id: item.id, name: item.friendlyName,
                                             reason: "没能移到废纸篓（\(detail)）。"))
            }
        }
    }

    /// 当前用户的废纸篓；不要在管理员脚本里用 $HOME，路径在这里就算好
    private static func userTrashDirectory() -> URL? {
        if let url = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
            return url
        }
        let fallback = Paths.home.appendingPathComponent(".Trash")
        return fallback
    }

    /// 废纸篓里已有同名文件时，在文件名里加上时间；reserved 避免同一批里两个文件抢同一个名字
    private static func uniqueURL(in folder: URL, matching source: URL, reserved: inout Set<String>) -> URL {
        let ext = source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        let names = [
            source.lastPathComponent,
            ext.isEmpty ? "\(base) \(stamp)" : "\(base) \(stamp).\(ext)",
            ext.isEmpty ? "\(base) \(stamp)-\(UUID().uuidString.prefix(6))"
                        : "\(base) \(stamp)-\(UUID().uuidString.prefix(6)).\(ext)"
        ]
        for name in names {
            let url = folder.appendingPathComponent(name)
            if !reserved.contains(url.path), !FileManager.default.fileExists(atPath: url.path) {
                reserved.insert(url.path)
                return url
            }
        }
        let fallback = folder.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
        reserved.insert(fallback.path)
        return fallback
    }

    private static func isAdminCancelled(_ r: Shell.Result) -> Bool {
        let s = r.output.lowercased()
        return s.contains("user canceled") || s.contains("user cancelled") || s.contains("-128")
    }

    // MARK: - 从备份还原已清理的残留项

    /// 一份可以还原的清理备份（原处的配置已经不在了）
    struct RestorableCleanup: Identifiable, Equatable, Sendable {
        let backupURL: URL
        let label: String
        let name: String
        let originalPath: String
        let scope: ServiceItem.Scope
        let date: Date

        var id: String { backupURL.path }

        /// /Library 下的配置需要管理员权限才能放回去
        var needsAdmin: Bool { scope == .allUsers || scope == .daemon }

        var scopeTitle: String {
            switch scope {
            case .user: return "仅当前用户"
            case .allUsers: return "所有用户"
            case .daemon: return "系统级"
            case .systemAgent, .systemDaemon: return "系统服务"
            }
        }

        var friendlyDate: String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            let cal = Calendar.current
            if cal.component(.year, from: date) == cal.component(.year, from: Date()) {
                f.dateFormat = "M 月 d 日 HH:mm"
            } else {
                f.dateFormat = "yyyy 年 M 月 d 日 HH:mm"
            }
            return f.string(from: date)
        }
    }

    enum RestoreCleanupResult: Sendable {
        case success(String)
        case failure(String)
        case cancelled
    }

    static func restoreConfirmTitle(for backup: RestorableCleanup) -> String {
        "确定把「\(backup.name)」的配置放回原处吗？"
    }

    static func restoreConfirmMessage(for backup: RestorableCleanup) -> String {
        var parts = ["只会把配置文件放回去，不会自动开启。如果那个程序还没装回来，它仍会显示为残留项，之后可以再清理。"]
        if backup.needsAdmin {
            parts.append("这一项在系统目录里，可能要输入一次登录密码。")
        }
        return parts.joined()
    }

    /// 清理时留下的、原处已经没有文件的备份。编辑时的备份、系统路径、以及已经又出现在列表里的项都不会出现。
    static func restorableCleanupBackups(excluding existing: [ServiceItem] = []) -> [RestorableCleanup] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)) ?? []
        let occupied = Set(existing.map { $0.scope.rawValue + "/" + $0.label })
        var result: [RestorableCleanup] = []
        for jsonURL in files where jsonURL.pathExtension == "json" {
            let plistURL = jsonURL.deletingPathExtension().appendingPathExtension("plist")
            guard fm.fileExists(atPath: plistURL.path),
                  let data = try? Data(contentsOf: jsonURL),
                  let meta = try? JSONDecoder().decode(CleanupBackupMeta.self, from: data),
                  meta.reason == "orphan-cleanup",
                  let item = makeRestorable(from: meta, backupURL: plistURL),
                  !occupied.contains(item.scope.rawValue + "/" + item.label)
            else { continue }
            result.append(item)
        }
        return result.sorted { $0.date > $1.date }
    }

    private static func makeRestorable(from meta: CleanupBackupMeta, backupURL: URL) -> RestorableCleanup? {
        guard meta.reason == "orphan-cleanup" else { return nil }
        guard !meta.label.hasPrefix(MyTask.labelPrefix) else { return nil }
        guard let scope = ServiceItem.Scope(rawValue: meta.scope),
              scope == .user || scope == .allUsers || scope == .daemon
        else { return nil }
        guard let dest = validatedRestoreDestination(path: meta.originalPath, scope: scope) else { return nil }
        if FileManager.default.fileExists(atPath: dest.path) { return nil }

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let date = stamp.date(from: meta.createdAt)
            ?? ((try? backupURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast)

        return RestorableCleanup(
            backupURL: backupURL,
            label: meta.label,
            name: meta.name,
            originalPath: dest.path,
            scope: scope,
            date: date
        )
    }

    /// 只允许还原到三个第三方自启动目录里的一份 .plist，不允许任何子目录或系统路径。
    static func validatedRestoreDestination(path: String, scope: ServiceItem.Scope) -> URL? {
        let allowed: URL
        switch scope {
        case .user: allowed = Paths.userAgents
        case .allUsers: allowed = Paths.globalAgents
        case .daemon: allowed = Paths.globalDaemons
        case .systemAgent, .systemDaemon: return nil
        }
        let dest = URL(fileURLWithPath: path).standardizedFileURL
        guard dest.pathExtension.lowercased() == "plist" else { return nil }
        let name = dest.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."), !name.contains("/"), !name.contains("\0") else {
            return nil
        }
        let parent = dest.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let allowedResolved = allowed.resolvingSymlinksInPath().standardizedFileURL
        guard parent.path == allowedResolved.path else { return nil }
        return dest
    }

    /// 把一份清理备份放回原来的位置。只还原文件，不自动加载或开启；系统目录需要管理员权限。
    static func restoreCleanupBackup(_ backup: RestorableCleanup) -> RestoreCleanupResult {
        // 当场再检查一遍，不信任列表打开时的状态
        guard !backup.label.hasPrefix(MyTask.labelPrefix) else {
            return .failure("这是启动台助手自己的任务，不能从这里还原。")
        }
        guard let dest = validatedRestoreDestination(path: backup.originalPath, scope: backup.scope) else {
            return .failure("「\(backup.name)」的原位置不在允许还原的目录里，没有放回去。")
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            return .failure("「\(backup.name)」原来的位置已经有一份配置了，没有覆盖。")
        }
        guard FileManager.default.fileExists(atPath: backup.backupURL.path) else {
            return .failure("「\(backup.name)」的备份文件已经不在了。")
        }
        do {
            try validate(backup.backupURL)
        } catch {
            return .failure("「\(backup.name)」的备份读不出来，没有还原（\(FriendlyError.text(error.localizedDescription))）。")
        }
        guard let dict = PlistIO.read(backup.backupURL) else {
            return .failure("「\(backup.name)」的备份读不出来，没有还原。")
        }
        if let label = dict["Label"] as? String, label != backup.label {
            return .failure("「\(backup.name)」的备份已经变了，没有还原。")
        }
        if dict["Label"] == nil {
            return .failure("「\(backup.name)」的备份已经变了，没有还原。")
        }

        if backup.needsAdmin {
            let q = Shell.shellQuote
            let script = "/bin/mkdir -p \(q(dest.deletingLastPathComponent().path)) && /bin/cp -n \(q(backup.backupURL.path)) \(q(dest.path)) && /usr/sbin/chown root:wheel \(q(dest.path)) && /bin/chmod 644 \(q(dest.path))"
            let r = Shell.runAsAdmin(script: script)
            if isAdminCancelled(r) {
                return .cancelled
            }
            if !FileManager.default.fileExists(atPath: dest.path) {
                let detail = r.ok ? "放回原处时出了点问题。" : FriendlyError.text(r.output)
                return .failure("「\(backup.name)」没能还原（\(detail)）。")
            }
        } else {
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: backup.backupURL, to: dest)
            } catch {
                return .failure("「\(backup.name)」没能还原（\(FriendlyError.text(error.localizedDescription))）。")
            }
        }

        var text = "已经把「\(backup.name)」的配置放回原处。不会自动开启，你可以在列表里看到它。"
        let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
        if ServiceItem.isProgramMissing(program) {
            text += "那个程序现在还不在，它仍会显示为残留项。"
        }
        return .success(text)
    }
}
