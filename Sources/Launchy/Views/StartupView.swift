import SwiftUI
import AppKit

/// 「开机自启动」：第三方程序装的后台服务
struct StartupView: View {
    @EnvironmentObject var store: ServicesStore
    @State private var search = ""
    @State private var query = ""
    @State private var selected: ServiceItem?

    private func items(_ scope: ServiceItem.Scope) -> [ServiceItem] {
        store.startupItems.filter { item in
            item.scope == scope && (query.isEmpty
                || item.friendlyName.localizedCaseInsensitiveContains(query)
                || item.label.localizedCaseInsensitiveContains(query))
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
                                        status: item.statusText,
                                        statusColor: item.pendingReboot ? .orange : (item.isDisabled ? .gray : (item.isRunning ? .green : .secondary)),
                                        isOn: Binding(get: { !item.isDisabled },
                                                      set: { store.setEnabled(item, $0) }),
                                        toggleDisabled: store.isWorking,
                                        iconView: AnyView(ServiceIconView(item: item)))
                                .contentShape(Rectangle())
                                .onTapGesture { selected = item }
                                .contextMenu {
                                    Button("查看详情") { selected = item }
                                    Button("在访达中显示") {
                                        NSWorkspace.shared.activateFileViewerSelecting([item.plistURL])
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                EmptyListOverlay(isLoading: store.isLoading,
                                 isEmpty: [ServiceItem.Scope.user, .allUsers, .daemon].allSatisfy { items($0).isEmpty },
                                 query: query,
                                 emptyText: "没有发现第三方的自启动项，电脑很干净。")
            }
            Text("提示：关掉不常用的自启动项可以让开机更快，随时都能再打开。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .navigationTitle("开机自启动")
        .navigationSubtitle("登录后会自动在后台运行的第三方程序")
        .searchable(text: $search, prompt: "搜索程序…")
        .debounced(search, into: $query)
        .toolbar {
            if store.isWorking { ProgressView().controlSize(.small) }
            Button { store.reload(); store.refreshStates(force: true) } label: { Label("刷新", systemImage: "arrow.clockwise") }
        }
        .sheet(item: $selected) { ServiceDetailView(item: $0) }
        .errorAlert($store.lastError)
    }
}
