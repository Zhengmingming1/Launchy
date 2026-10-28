import SwiftUI

/// 左侧栏的三个页面
enum Page: String, CaseIterable, Identifiable {
    case myTasks, startup, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .myTasks: return "我的任务"
        case .startup: return "开机自启动"
        case .system: return "系统服务"
        }
    }
    var icon: String {
        switch self {
        case .myTasks: return "alarm"
        case .startup: return "bolt.circle"
        case .system: return "gearshape.2"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var tasks: MyTasksStore
    @EnvironmentObject var services: ServicesStore
    @State private var page: Page? = .myTasks

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section("管理") {
                    ForEach(Page.allCases) { p in
                        Label(p.title, systemImage: p.icon)
                            .badge(count(for: p))
                            .tag(p)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch page ?? .myTasks {
            case .myTasks: MyTasksView()
            case .startup: StartupView()
            case .system: SystemServicesView()
            }
        }
    }

    private func count(for page: Page) -> Int {
        switch page {
        case .myTasks: return tasks.tasks.count
        case .startup: return services.startupItems.count
        case .system: return services.systemItems.count
        }
    }
}

/// 列表里通用的一行：图标 + 名字 + 说明 + 状态标签 + 开关
struct ItemRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let status: String
    let statusColor: Color
    @Binding var isOn: Bool
    var toggleDisabled = false
    /// 有值时用它代替 SF Symbol 图标（服务列表用真实的 app 图标）
    var iconView: AnyView? = nil
    /// 副标题下面再加一行小字（例如「上次运行成功」），为 nil 时不显示
    var footnote: String? = nil
    var footnoteColor: Color = .secondary
    /// 小字后面跟一个「怎么修」的小按钮（例如「重新选择…」），为 nil 时不显示
    var footnoteButton: (title: String, action: () -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            if let iconView {
                iconView
            } else {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let footnote {
                    HStack(spacing: 6) {
                        Text(footnote).font(.caption2).foregroundStyle(footnoteColor).lineLimit(1)
                        if let footnoteButton {
                            Button(footnoteButton.title, action: footnoteButton.action)
                                .buttonStyle(.link)
                                .font(.caption2.weight(.semibold))
                                .fixedSize()
                        }
                    }
                }
            }
            Spacer()
            Text(status)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(statusColor)
                .background(statusColor.opacity(0.12), in: Capsule())
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(toggleDisabled)
        }
        .padding(.vertical, 6)
        // VoiceOver：整行读成一句「名字，状态」，开关状态作为值，用「操作」菜单切换
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(spokenStatus)")
        .accessibilityValue(isOn ? "开启" : "关闭")
        .accessibilityHint(toggleDisabled ? "\(hintText)。开关当前不可用" : "\(hintText)。可在操作菜单中切换开关")
        .accessibilityAction(named: isOn ? "关闭" : "开启") {
            if !toggleDisabled { isOn.toggle() }
        }
    }

    private var hintText: String {
        guard let footnote else { return subtitle }
        // 有「怎么修」按钮时顺便告诉读屏用户：操作菜单里有同名的一项
        let fix = footnoteButton.map { "。可在操作菜单中选择「\($0.title.trimmingCharacters(in: CharacterSet(charactersIn: "…")))」" } ?? ""
        return "\(subtitle)。\(footnote)\(fix)"
    }

    /// 去掉状态里的表情符号（⚠️、🔒），避免 VoiceOver 念出「警告符号」之类的噪音
    private var spokenStatus: String {
        let scalars = status.unicodeScalars.filter { s in
            s.isASCII || !(s.properties.isEmojiPresentation || s.properties.isEmoji || s.properties.isVariationSelector)
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }
}

/// 把 store 里的错误信息弹成提示框
struct ErrorAlert: ViewModifier {
    @Binding var message: String?
    func body(content: Content) -> some View {
        content.alert("出了点小问题", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }
}

/// 只在条件成立时才加的 VoiceOver 操作（避免菜单里出现用不上的项）
struct ConditionalAccessibilityAction: ViewModifier {
    let enabled: Bool
    let name: String
    let handler: () -> Void
    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAction(named: name, handler)
        } else {
            content
        }
    }
}

extension View {
    func optionalAccessibilityAction(if enabled: Bool, named name: String, _ handler: @escaping () -> Void) -> some View {
        modifier(ConditionalAccessibilityAction(enabled: enabled, name: name, handler: handler))
    }

    func errorAlert(_ message: Binding<String?>) -> some View { modifier(ErrorAlert(message: message)) }
}

/// 列表为空时的提示：读取中 / 没有内容 / 搜索没结果
struct EmptyListOverlay: View {
    let isLoading: Bool
    let isEmpty: Bool
    let query: String
    let emptyText: String

    var body: some View {
        if isLoading {
            ProgressView("正在读取…")
        } else if isEmpty {
            VStack(spacing: 10) {
                Image(systemName: query.isEmpty ? "tray" : "magnifyingglass")
                    .font(.system(size: 36)).foregroundStyle(.secondary)
                Text(query.isEmpty ? emptyText : "没有找到和「\(query)」相关的项目")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    /// 搜索防抖：停止输入 0.25 秒后才把 text 同步到 query，避免每敲一个字就重新过滤几百项
    func debounced(_ text: String, into query: Binding<String>) -> some View {
        task(id: text) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            query.wrappedValue = text
        }
    }
}
