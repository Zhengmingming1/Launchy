import Foundation

extension ServiceEditor {
    /// 清理一批残留自启动项的结果（先备份再移到废纸篓）
    struct CleanResult: Sendable {
        struct Item: Sendable {
            let id: String
            let name: String
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
        parts.append("会先备份一份，之后可以在废纸篓里找回来。不会永久删除，也不会动其他自启动项。")
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
            if let failure = trashUserOrphan(item) {
                result.failures.append(failure)
            } else {
                result.trashed.append(.init(id: item.id, name: item.friendlyName))
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
            try backup(item)
        } catch {
            return fail("没能备份，所以没有移到废纸篓。")
        }
        return nil
    }

    // MARK: - 当前用户目录

    /// 备份之后：先卸载（本来就没加载也没关系），清掉停用记录，再移到废纸篓
    private static func trashUserOrphan(_ item: ServiceItem) -> CleanResult.Failure? {
        Launchctl.bootout(domain: item.scope.domain, label: item.label)
        Launchctl.enable(domain: item.scope.domain, label: item.label)
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: item.plistURL, resultingItemURL: &resulting)
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
        var script = "ok=0"
        let q = Shell.shellQuote
        let lc = q(Launchctl.path)
        let owner = "\(getuid()):\(getgid())"

        for item in items {
            let dest = uniqueURL(in: trash, matching: item.plistURL, reserved: &reserved)
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
                result.trashed.append(.init(id: item.id, name: item.friendlyName))
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
}
