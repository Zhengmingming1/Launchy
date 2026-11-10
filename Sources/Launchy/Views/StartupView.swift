import SwiftUI
import AppKit

/// 「开机自启动」顶部的分段筛选
enum StartupFilter: String, CaseIterable, Identifiable {
    case all, enabled, disabled, orphan, recent
    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部"
        case .enabled: return "已开启"
        case .disabled: return "已停用"
        case .orphan: return "残留"
        case .recent: return "最近新增"
        }
    }

    /// 没有符合条件的项目时显示的话
    var emptyText: String {
        switch self {
        case .all: return "没有发现第三方的自启动项，电脑很干净。"
        case .enabled: return "所有自启动项都已经关掉了。"
        case .disabled: return "还没有关掉任何自启动项。"
        case .orphan: return "没有残留项，卸载得很干净。"
        case .recent: return "最近 7 天没有新冒出来的自启动项。"
        }
    }

    func matches(_ item: ServiceItem) -> Bool {
        switch self {
        case .all: return true
        case .enabled: return !item.isDisabled
        case .disabled: return item.isDisabled
        // 残留项关掉后仍然留在这里，方便确认已经处理过
        case .orphan: return item.programMissing
        // 最近 7 天新装的软件加进来的自启动项
        case .recent: return item.newSince != nil
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
    /// 用户自己点过分段后，就不要再自动切到「最近新增」（避免正在看残留/全部时被抢走）
    @State private var userChoseFilter = false

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

    /// 「最近新增」筛选下当前看得到的新增项（跟随搜索词）
    private var visibleNewItems: [ServiceItem] {
        store.startupItems.filter { $0.newSince != nil && matchesQuery($0) }
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
                        Button("只看残留项") { chooseFilter(.orphan) }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .top], 12)
            }
            // 装一套软件常常同时加好几个自启动项：在「最近新增」里提供「全部知道了」，不用逐个点
            if filter == .recent, visibleNewItems.count >= 2 {
                let n = visibleNewItems.count
                HStack(alignment: .center, spacing: 10) {
                    Label("这 \(n) 个是最近 7 天新出现的自启动项。逐个看过、都认识的话，可以一次全部确认，蓝色提醒就会消失（不会关掉它们）。",
                          systemImage: "sparkles")
                        .font(.callout)
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    Button("全部知道了") { acknowledgeAllVisible() }
                        .controlSize(.small)
                        .help("把这 \(n) 个都标为看过，不再显示蓝色提醒")
                        .accessibilityHint("把这 \(n) 个自启动项都标为看过，不会关掉它们")
                }
                .padding(10)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .top], 12)
            }
            Picker("显示", selection: filterBinding) {
                // 「最近新增」只在有新项（或正选着它）时出现，平时不占位置
                ForEach(StartupFilter.allCases.filter { $0 != .recent || filter == .recent || count(.recent) > 0 }) { f in
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
                                        iconView: AnyView(ServiceIconView(item: item)),
                                        footnote: item.newSince.map {
                                            "新出现的自启动项（\(NewItemTracker.describe($0)) 发现），不认识可以点开看看是谁做的"
                                        },
                                        footnoteColor: .blue,
                                        footnoteButton: item.newSince == nil ? nil
                                            : (title: "知道了", action: { store.acknowledgeNew(item) }))
                                .contentShape(Rectangle())
                                .onTapGesture { selected = item }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { selected = item }
                                .accessibilityAction(named: "查看详情") { selected = item }
                                .optionalAccessibilityAction(if: item.newSince != nil, named: "知道了") {
                                    store.acknowledgeNew(item)
                                }
                                .accessibilityAction(named: "在访达中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.plistURL])
                                }
                                .contextMenu {
                                    Button("查看详情") { selected = item }
                                    if item.newSince != nil {
                                        Button("不再标为新增") { store.acknowledgeNew(item) }
                                    }
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
        .onAppear { suggestRecentFilterIfNeeded() }
        // 第一次扫描还没完成就点进来时，等结果出来再决定要不要切到「最近新增」
        .onChange(of: store.isLoading) { loading in
            if !loading { suggestRecentFilterIfNeeded() }
        }
    }

    /// 分段控件：用户亲手切换时记一笔，之后不再自动改筛选
    private var filterBinding: Binding<StartupFilter> {
        Binding(get: { filter }, set: { chooseFilter($0) })
    }

    private func chooseFilter(_ newValue: StartupFilter) {
        filter = newValue
        userChoseFilter = true
    }

    /// 「全部知道了」：确认当前看得到的新增项；都确认完了就回到「全部」，不留一个空列表
    private func acknowledgeAllVisible() {
        withAnimation {
            store.acknowledgeNew(visibleNewItems)
            if !store.startupItems.contains(where: { $0.newSince != nil }) {
                filter = .all
            }
        }
    }

    /// 有未确认的新增项时，点进这一页就直接看到它们（侧栏蓝点的配套动作）
    private func suggestRecentFilterIfNeeded() {
        guard !userChoseFilter, filter != .recent else { return }
        if store.startupItems.contains(where: { $0.newSince != nil }) {
            filter = .recent
        }
    }
}
