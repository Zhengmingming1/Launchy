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

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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

extension View {
    func errorAlert(_ message: Binding<String?>) -> some View { modifier(ErrorAlert(message: message)) }
}
