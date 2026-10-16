import SwiftUI
import AppKit

/// 根据程序路径或 bundle id 找到服务所属的 .app
enum AppResolver {
    static func resolve(label: String, program: String?, extraBundleIDs: [String] = []) -> URL? {
        // 1. 程序路径里包含 .app，就往上找到最外层的那个 .app
        //    例如 /Applications/Foo.app/Contents/Library/LoginItems/Bar.app/... -> Foo.app
        if let program, let range = program.range(of: ".app/") ?? program.range(of: ".app", options: .backwards),
           range.upperBound <= program.endIndex {
            let path = String(program[..<range.lowerBound]) + ".app"
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        // 2. 用 bundle id 查：先查 plist 里声明的，再按标签逐级去掉最后一段去猜
        var ids = extraBundleIDs
        var parts = label.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            ids.append(parts.joined(separator: "."))
            parts.removeLast()
        }
        for id in ids where id.contains(".") {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }
}

/// 找不到 app 时，按关键词选一个有颜色的 SF Symbol
enum IconCategory {
    static func symbol(label: String, program: String?, isApple: Bool) -> (name: String, color: Color) {
        let t = (label + " " + (program ?? "")).lowercased()
        func has(_ keys: String...) -> Bool { keys.contains { t.contains($0) } }
        if has("update", "updater", "keystone", "upgrade") { return ("arrow.triangle.2.circlepath.circle.fill", .green) }
        if has("sync", "cloud", "drive", "backup") { return ("icloud.fill", .cyan) }
        if has("clean", "lemon", "trash", "cache") { return ("sparkles", .mint) }
        if has("vpn", "network", "secureclient", "pulse", "wifi", "proxy", "dns") { return ("network", .blue) }
        if has("security", "posture", "antivirus", "firewall", "guard", "auth") { return ("lock.shield.fill", .red) }
        if has("bluetooth") { return ("dot.radiowaves.left.and.right", .blue) }
        if has("print", "scan") { return ("printer.fill", .gray) }
        if has("audio", "sound", "music") { return ("speaker.wave.2.fill", .pink) }
        if has("photo", "media", "camera", "video") { return ("photo.fill", .orange) }
        if has("wake", "quit", "timer", "schedule") { return ("alarm.fill", .orange) }
        if has("helper", "agent") && !isApple { return ("wrench.and.screwdriver.fill", .purple) }
        if has("mysql", "redis", "postgres", "database", "docker") { return ("cylinder.split.1x2.fill", .indigo) }
        if isApple { return ("gearshape.fill", .gray) }
        return ("app.dashed", .secondary)
    }
}

/// 图标缓存：在后台查找 app 并读取图标，读到后刷新界面
@MainActor
final class IconProvider: ObservableObject {
    static let shared = IconProvider()

    @Published private var icons: [String: NSImage] = [:]
    private var missing = Set<String>()   // 已经确认找不到 app 的
    private var loading = Set<String>()

    func icon(for key: String) -> NSImage? { icons[key] }
    func isMissing(_ key: String) -> Bool { missing.contains(key) }

    func load(key: String, label: String, program: String?) {
        guard icons[key] == nil, !missing.contains(key), !loading.contains(key) else { return }
        loading.insert(key)
        DispatchQueue.global(qos: .utility).async {
            let url = AppResolver.resolve(label: label, program: program)
            let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            DispatchQueue.main.async {
                self.loading.remove(key)
                if let image { self.icons[key] = image } else { self.missing.insert(key) }
            }
        }
    }
}

/// 列表和详情页里的服务图标
struct ServiceIconView: View {
    let item: ServiceItem
    var size: CGFloat = 38
    @ObservedObject private var provider = IconProvider.shared

    var body: some View {
        Group {
            if let image = provider.icon(for: item.id) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                let isApple = item.scope == .systemAgent || item.scope == .systemDaemon
                let s = IconCategory.symbol(label: item.label, program: item.program, isApple: isApple)
                Image(systemName: s.name)
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(s.color)
                    .frame(width: size, height: size)
                    .background(s.color.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.24))
            }
        }
        .frame(width: size, height: size)
        .onAppear { provider.load(key: item.id, label: item.label, program: item.program) }
    }
}
