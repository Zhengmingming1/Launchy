import Foundation
import Security

/// 读程序的代码签名，用大白话说出「这是谁做的」。
/// 只用 Security 框架读取，不启动子进程、不改任何文件。
/// 借鉴 objective-see/KnockKnock 按签名区分「苹果 / App Store / 认证开发者 / 未签名」的想法，没有使用其代码。
enum CodeSignature {
    enum Kind: Equatable, Sendable {
        /// 苹果自己的程序
        case apple
        /// 从 Mac App Store 下载的
        case appStore(developer: String?)
        /// 苹果认证过的开发者（Developer ID）
        case developerID(developer: String)
        /// 有签名但不是苹果认证的证书（自签名、本机编译、Homebrew 等）
        case adHoc
        /// 完全没有签名
        case unsigned
        /// 签名对不上：文件在签名后被改动过
        case invalid
        /// 文件找不到或读不了
        case unknown
    }

    struct Result: Equatable, Sendable {
        let kind: Kind
        /// 实际检查的文件（.app 或可执行文件 / 脚本）
        let checkedPath: String
        /// 检查的是参数里的脚本，而不是解释器本身
        let isScript: Bool

        /// 一句话结论
        var title: String {
            switch kind {
            case .apple: return "苹果公司"
            case .appStore(let dev): return dev.map { "\($0)（来自 Mac App Store）" } ?? "来自 Mac App Store"
            case .developerID(let dev): return "\(dev)（苹果认证的开发者）"
            case .adHoc: return "没有开发者签名"
            case .unsigned: return isScript ? "脚本文件，没有签名" : "未签名，无法确认是谁做的"
            case .invalid: return "签名无效"
            case .unknown: return "无法检查"
            }
        }

        /// 补充说明：这意味着什么、要不要担心
        var explanation: String {
            switch kind {
            case .apple:
                return "这是苹果签名的程序，可以放心。"
            case .appStore:
                return "这个程序经过了苹果 App Store 审核。"
            case .developerID:
                return "开发者的身份经过了苹果验证。如果你装过这家公司的软件，它多半就是那个软件的组件。"
            case .adHoc:
                return "自己编译的程序或用 Homebrew 装的工具常常这样，不一定有问题。如果你不认识它，可以先关掉观察一下。"
            case .unsigned:
                return isScript
                    ? "脚本通常都没有签名，这很正常。可以在访达中打开它看看里面写了什么。"
                    : "没有签名的程序无法确认来源。如果你不认识它，建议先关掉。"
            case .invalid:
                return "程序在签名之后被改动过，可能是更新没装完整，也可能被篡改了。如果你不认识它，建议关掉，并重新安装对应的软件。"
            case .unknown:
                return "找不到要检查的文件，或者没有权限读取。"
            }
        }

        /// 需要提醒用户留意（橙色显示）
        var needsAttention: Bool {
            switch kind {
            case .unsigned: return !isScript
            case .invalid: return true
            default: return false
            }
        }
    }

    /// 常见的脚本解释器：程序是它们时，真正要看的是参数里的脚本文件
    private static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "tcsh", "csh", "fish",
        "python", "python3", "perl", "ruby", "node", "osascript", "php", "env"
    ]

    /// 根据 plist 的程序和参数，决定检查哪个文件
    static func target(program: String?, arguments: [String]) -> (path: String, isScript: Bool)? {
        guard let program, program.hasPrefix("/") else { return nil }
        let name = (program as NSString).lastPathComponent
        if interpreters.contains(name) {
            // 跳过 -c、-l 之类的选项，找第一个像文件路径的参数
            let rest = (arguments.first == program ? Array(arguments.dropFirst()) : arguments)
            if let script = rest.first(where: { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }) {
                return (script, true)
            }
        }
        // 程序在某个 .app 里时，检查整个 .app（签名信息更完整）
        if let r = program.range(of: ".app/") {
            return (String(program[..<r.lowerBound]) + ".app", false)
        }
        return (program, false)
    }

    /// 检查签名。读取 .app 时可能要几十毫秒，请在后台线程调用。
    static func check(program: String?, arguments: [String]) -> Result? {
        guard let t = target(program: program, arguments: arguments) else { return nil }
        return Result(kind: kind(at: t.path), checkedPath: t.path, isScript: t.isScript)
    }

    static func kind(at path: String) -> Kind {
        guard FileManager.default.fileExists(atPath: path) else { return .unknown }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return .unknown }

        var infoRef: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        guard infoStatus == errSecSuccess, let info = infoRef as? [String: Any] else {
            return infoStatus == errSecCSUnsigned ? .unsigned : .unknown
        }
        // 没有 identifier 说明根本没签名
        guard info[kSecCodeInfoIdentifier as String] != nil else { return .unsigned }

        // 只验证签名本身和可执行文件，不逐个哈希 .app 里的资源，避免大程序卡顿
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        let validity = SecStaticCodeCheckValidity(code, flags, nil)
        if validity == errSecCSUnsigned { return .unsigned }
        if validity != errSecSuccess {
            // 证书过期等情况不算篡改；只有签名对不上才报「无效」
            let tampered: Set<OSStatus> = [errSecCSSignatureFailed, errSecCSSignatureInvalid, errSecCSBadResource]
            return tampered.contains(validity) ? .invalid : .adHoc
        }

        let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        guard let leaf = certs.first else { return .adHoc }
        let leafName = (SecCertificateCopySubjectSummary(leaf) as String?) ?? ""

        if satisfies(code, "anchor apple") { return .apple }
        if leafName.hasPrefix("Apple Mac OS Application Signing") || leafName.hasPrefix("Apple iPhone OS Application Signing") {
            return .appStore(developer: nil)
        }
        if satisfies(code, "anchor apple generic") {
            let dev = developerName(from: leafName) ?? (info[kSecCodeInfoTeamIdentifier as String] as? String) ?? leafName
            if leafName.hasPrefix("Developer ID") { return .developerID(developer: dev) }
            if leafName.hasPrefix("Apple Distribution") || leafName.hasPrefix("3rd Party Mac Developer") {
                return .appStore(developer: dev)
            }
            // Apple Development 等开发证书：身份是苹果签发的
            return .developerID(developer: dev)
        }
        return .adHoc
    }

    private static func satisfies(_ code: SecStaticCode, _ requirement: String) -> Bool {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), req) == errSecSuccess
    }

    /// 「Developer ID Application: Google LLC (EQHXZ8M8AV)」→「Google LLC」
    static func developerName(from summary: String) -> String? {
        guard let colon = summary.range(of: ": ") else { return nil }
        var name = String(summary[colon.upperBound...])
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
            name = String(name[..<open.lowerBound])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
