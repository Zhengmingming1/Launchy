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

    /// 还开着、但程序已经不存在的自启动项
    private var orphanCount: Int {
        store.startupItems.filter { $0.programMissing && !$0.isDisabled }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            if orphanCount > 0 {
                Label("发现 \(orphanCount) 个残留项：它们指向的程序已经被删除（多半是软件卸载后没清理干净），开机时只会白白报错。可以放心关掉，随时还能再打开。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .padding([.horizontal, .top], 12)
                    .accessibilityElement(children: .combine)
            }
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
                                        status: item.programMissing && !item.isDisabled && !item.pendingReboot
                                            ? "⚠️ 程序已删除" : item.statusText,
                                        statusColor: item.pendingReboot || (item.programMissing && !item.isDisabled)
                                            ? .orange : (item.isDisabled ? .gray : (item.isRunning ? .green : .secondary)),
                                        isOn: Binding(get: { !item.isDisabled },
                                                      set: { store.setEnabled(item, $0) }),
                                        toggleDisabled: store.isWorking,
                                        iconView: AnyView(ServiceIconView(item: item)))
                                .contentShape(Rectangle())
                                .onTapGesture { selected = item }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { selected = item }
                                .accessibilityAction(named: "查看详情") { selected = item }
                                .accessibilityAction(named: "在访达中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.plistURL])
                                }
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
