import SwiftUI
import AppKit

/// 「开机自启动」：第三方程序装的后台服务
struct StartupView: View {
    @EnvironmentObject var store: ServicesStore
    @State private var search = ""

    private func items(_ scope: ServiceItem.Scope) -> [ServiceItem] {
        store.startupItems.filter { item in
            item.scope == scope && (search.isEmpty
                || item.friendlyName.localizedCaseInsensitiveContains(search)
                || item.label.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach([ServiceItem.Scope.user, .allUsers, .daemon], id: \.self) { scope in
                    let list = items(scope)
                    if !list.isEmpty {
                        Section(scope.title) {
                            ForEach(list) { item in
                                ItemRow(icon: scope.needsAdmin ? "key" : "app.connected.to.app.below.fill",
                                        tint: .blue,
                                        title: item.friendlyName,
                                        subtitle: item.label,
                                        status: item.isDisabled ? "已关闭" : (item.isRunning ? "运行中" : "已启用"),
                                        statusColor: item.isDisabled ? .gray : .green,
                                        isOn: Binding(get: { !item.isDisabled },
                                                      set: { store.setEnabled(item, $0) }))
                                .contextMenu {
                                    Button("在访达中显示") {
                                        NSWorkspace.shared.activateFileViewerSelecting([item.plistURL])
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Text("提示：关掉不常用的自启动项可以让开机更快，随时都能再打开。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .navigationTitle("开机自启动")
        .navigationSubtitle("登录后会自动在后台运行的第三方程序")
        .searchable(text: $search, prompt: "搜索程序…")
        .toolbar {
            Button { store.reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }
        }
        .errorAlert($store.lastError)
    }
}
