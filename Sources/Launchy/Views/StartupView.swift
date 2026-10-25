import SwiftUI
import AppKit

/// 「开机自启动」顶部的分段筛选
enum StartupFilter: String, CaseIterable, Identifiable {
    case all, enabled, disabled, orphan
    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部"
        case .enabled: return "已开启"
        case .disabled: return "已停用"
        case .orphan: return "残留"
        }
    }

    /// 没有符合条件的项目时显示的话
    var emptyText: String {
        switch self {
        case .all: return "没有发现第三方的自启动项，电脑很干净。"
        case .enabled: return "所有自启动项都已经关掉了。"
        case .disabled: return "还没有关掉任何自启动项。"
        case .orphan: return "没有残留项，卸载得很干净。"
        }
    }

    func matches(_ item: ServiceItem) -> Bool {
        switch self {
        case .all: return true
        case .enabled: return !item.isDisabled
        case .disabled: return item.isDisabled
        // 残留项关掉后仍然留在这里，方便确认已经处理过
        case .orphan: return item.programMissing
        }
    }
}

/// 「开机自启动」：第三方程序装的后台服务
struct StartupView: View {
    @EnvironmentObject var store: ServicesStore
    @State private var search = ""
    @State private var query = ""
    @State private var selected: ServiceItem?
    @State private var filter: StartupFilter = .all

    private func matchesQuery(_ item: ServiceItem) -> Bool {
        query.isEmpty
            || item.friendlyName.localizedCaseInsensitiveContains(query)
            || item.label.localizedCaseInsensitiveContains(query)
    }

    private func items(_ scope: ServiceItem.Scope) -> [ServiceItem] {
        store.startupItems.filter { item in
            item.scope == scope && filter.matches(item) && matchesQuery(item)
        }
    }

    /// 每个筛选项后面显示的数量（跟随搜索词）
    private func count(_ f: StartupFilter) -> Int {
        store.startupItems.filter { f.matches($0) && matchesQuery($0) }.count
    }

    /// 还开着、但程序已经不存在的自启动项
    private var orphanCount: Int {
        store.startupItems.filter { $0.programMissing && !$0.isDisabled }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            if orphanCount > 0 {
                HStack(alignment: .center, spacing: 10) {
                    Label("发现 \(orphanCount) 个残留项：它们指向的程序已经被删除（多半是软件卸载后没清理干净），开机时只会白白报错。可以放心关掉，随时还能再打开。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    if filter != .orphan {
                        Button("只看残留项") { filter = .orphan }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .top], 12)
            }
            Picker("显示", selection: $filter) {
                ForEach(StartupFilter.allCases) { f in
                    Text("\(f.title) \(count(f))").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 10)
            .padding(.bottom, 2)
            .accessibilityLabel("按状态筛选")
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
                                 emptyText: filter.emptyText)
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
