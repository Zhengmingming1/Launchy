import SwiftUI
import AppKit

/// 根据程序路径或 bundle id 找到服务所属的 .app
enum AppResolver {
    static func resolve(label: String, program: String?, extraBundleIDs: [String] = []) -> URL? {
        // 1. 程序路径里包含 .app，就往上找到最外层的那个 .app
        //    例如 /Applications/Foo.app/Contents/Library/LoginItems/Bar.app/... -> Foo.app
        if let program, let range = program.range(of: ".app/") {
            let path = String(program[..<range.lowerBound]) + ".app"
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        // 2. 用 bundle id 查：先查 plist 里声明的，再按标签逐级去掉最后一段去猜
        var ids = extraBundleIDs
        if label.hasPrefix("com.apple.") {
            // 苹果的服务只认精确的 bundle id，不逐级猜，免得配错图标（比如都变成 Siri）
            ids.append(label)
        } else {
            // 第三方：com.tencent.Lemon.monitor -> com.tencent.Lemon -> com.tencent，至少保留三段
            var parts = label.split(separator: ".").map(String.init)
            while parts.count >= 2 {
                ids.append(parts.joined(separator: "."))
                if parts.count <= 3 { break }
                parts.removeLast()
            }
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

/// 图标缓存：在后台查找 app 并读取图标，读到后刷新界面。
///
/// 省内存的两个做法（参考 p0deje/Maccy 按 app 共用图标的思路，没有使用其代码）：
/// 1. 同一个 app 的多个服务（例如 Adobe、Microsoft 一个软件带好几个自启动项）共用同一张图标，
///    不再每个服务各读一份。
/// 2. 系统给的 app 图标里带着从 16 到 1024 像素的多种尺寸，界面最大只用到 52 点。
///    读到后先缩成一张 128×128 像素的小图（Retina 屏上 64 点也清晰）再保存，原图随即释放。
@MainActor
final class IconProvider: ObservableObject {
    static let shared = IconProvider()

    /// 缩小后的图标边长（点）。界面上最大 52 点，留一点余量；按 2 倍像素绘制。
    nonisolated static let thumbnailPoints: CGFloat = 64

    @Published private var icons: [String: NSImage] = [:]   // 服务 id -> 图标（同一 app 的服务指向同一张图）
    private var appIcons: [String: NSImage] = [:]            // app 路径 -> 已缩小的图标
    private var missing = Set<String>()   // 已经确认找不到 app 的
    private var loading = Set<String>()

    func icon(for key: String) -> NSImage? { icons[key] }
    func isMissing(_ key: String) -> Bool { missing.contains(key) }

    func load(key: String, label: String, program: String?) {
        guard icons[key] == nil, !missing.contains(key), !loading.contains(key) else { return }
        loading.insert(key)
        DispatchQueue.global(qos: .utility).async {
            let url = AppResolver.resolve(label: label, program: program)
            DispatchQueue.main.async {
                guard let url else {
                    self.loading.remove(key)
                    self.missing.insert(key)
                    return
                }
                let path = url.path
                // 同一个 app 的图标已经读过：直接共用，不再读一遍
                if let shared = self.appIcons[path] {
                    self.loading.remove(key)
                    self.icons[key] = shared
                    return
                }
                DispatchQueue.global(qos: .utility).async {
                    let image = Self.thumbnail(NSWorkspace.shared.icon(forFile: path))
                    DispatchQueue.main.async {
                        self.loading.remove(key)
                        // 并发读同一个 app 时，以先读完的为准，保证只留一份
                        let kept = self.appIcons[path] ?? image
                        self.appIcons[path] = kept
                        self.icons[key] = kept
                    }
                }
            }
        }
    }

    /// 把系统图标画成一张固定大小的小位图。画不出来时退回原图，保证一定有图标显示。
    nonisolated static func thumbnail(_ source: NSImage) -> NSImage {
        let points = thumbnailPoints
        let pixels = Int(points * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return source }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: points, height: points),
                    from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
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
