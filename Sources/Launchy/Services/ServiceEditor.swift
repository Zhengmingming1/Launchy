import Foundation

/// 修改第三方服务的 plist：校验、备份、写入、重新加载。
enum ServiceEditor {
    static let backupDir = Paths.support.appendingPathComponent("backups")

    enum EditError: LocalizedError {
        case invalid(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let s): return "格式不对，没有保存。\n\n\(s)"
            case .failed(let s): return "保存失败。\n\n\(s)"
            }
        }
    }

    /// 用 plutil -lint 检查一份 plist 文件
    static func validate(_ url: URL) throws {
        let r = Shell.run("/usr/bin/plutil", ["-lint", url.path])
        guard r.ok else { throw EditError.invalid(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let dict = PlistIO.read(url), dict["Label"] is String else {
            throw EditError.invalid("缺少 Label 字段")
        }
        guard dict["Program"] is String || dict["ProgramArguments"] is [String] else {
            throw EditError.invalid("缺少 Program 或 ProgramArguments")
        }
    }

    /// 把当前文件备份一份，文件名带时间
    @discardableResult
    static func backup(_ item: ServiceItem) throws -> URL {
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let dest = backupDir.appendingPathComponent("\(item.label)__\(f.string(from: Date())).plist")
        try FileManager.default.copyItem(at: item.plistURL, to: dest)
        return dest
    }

    /// 这个服务的所有备份，最新的在前
    static func backups(for item: ServiceItem) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(item.label + "__") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// 保存一个字典
    static func save(_ dict: [String: Any], for item: ServiceItem) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("launchy-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try PlistIO.write(dict, to: tmp)
        try apply(tmp, to: item)
    }

    /// 保存一段原始 XML 文本
    static func save(rawText: String, for item: ServiceItem) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("launchy-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(rawText.utf8).write(to: tmp)
        try apply(tmp, to: item)
    }

    /// 校验 → 备份 → 覆盖原文件 → bootout + bootstrap 让它生效。
    /// /Library 下的文件需要管理员权限，所有步骤合成一次密码框。
    static func apply(_ newFile: URL, to item: ServiceItem) throws {
        try validate(newFile)
        try backup(item)

        let q = Shell.shellQuote
        let lc = q(Launchctl.path)
        let target = "\(item.scope.domain)/\(item.label)"
        let dest = item.plistURL.path

        switch item.scope {
        case .user:
            // 用户自己的文件，直接写
            let data = try Data(contentsOf: newFile)
            try data.write(to: item.plistURL, options: .atomic)
            Launchctl.bootout(domain: item.scope.domain, label: item.label)
            if !item.isDisabled { Launchctl.bootstrap(domain: item.scope.domain, plist: item.plistURL) }
        case .allUsers, .daemon:
            var script = "/bin/cp \(q(newFile.path)) \(q(dest)) && /usr/sbin/chown root:wheel \(q(dest)) && /bin/chmod 644 \(q(dest))"
            if item.scope == .daemon {
                script += " && { \(lc) bootout \(q(target)) 2>/dev/null; true; }"
                if !item.isDisabled { script += " && \(lc) bootstrap system \(q(dest))" }
            }
            let r = Shell.runAsAdmin(script: script)
            guard r.ok else { throw EditError.failed(FriendlyError.text(r.output)) }
            // /Library/LaunchAgents 属于用户会话，不用管理员就能重新加载
            if item.scope == .allUsers {
                Launchctl.bootout(domain: item.scope.domain, label: item.label)
                if !item.isDisabled { Launchctl.bootstrap(domain: item.scope.domain, plist: item.plistURL) }
            }
        case .systemAgent, .systemDaemon:
            throw EditError.failed("苹果系统服务受 SIP 保护，不能修改")
        }
    }

    // MARK: - 运行控制

    /// 立即运行一次
    static func runNow(_ item: ServiceItem) -> Shell.Result {
        control(item, ["kickstart", "\(item.scope.domain)/\(item.label)"])
    }

    /// 停止当前进程（KeepAlive 的服务可能会被马上拉起来）
    static func stop(_ item: ServiceItem) -> Shell.Result {
        control(item, ["kill", "SIGTERM", "\(item.scope.domain)/\(item.label)"])
    }

    private static func control(_ item: ServiceItem, _ args: [String]) -> Shell.Result {
        if item.scope.needsAdmin {
            return Shell.runAsAdmin(script: ([Launchctl.path] + args).map(Shell.shellQuote).joined(separator: " "))
        }
        return Shell.run(Launchctl.path, args)
    }
}
