import SwiftUI

/// 「系统服务」：苹果自带的服务。默认只读，打开「高级模式」才能停用。
struct SystemServicesView: View {
    @EnvironmentObject var store: ServicesStore
    @AppStorage("advancedMode") private var advancedMode = false
    @State private var search = ""
    @State private var askAdvanced = false
    @State private var showHistory = false
    @State private var confirmRestore = false

    private var filtered: [ServiceItem] {
        guard !search.isEmpty else { return store.systemItems }
        return store.systemItems.filter {
            $0.friendlyName.localizedCaseInsensitiveContains(search)
                || $0.label.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Label("这些服务受苹果系统保护（SIP），文件不能修改。打开「高级模式」后可以停用，一般重启后生效；随时可以一键恢复。",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .top], 12)

            List(filtered) { item in
                ItemRow(icon: "lock.fill",
                        tint: .indigo,
                        title: item.friendlyName,
                        subtitle: item.detail,
                        status: item.isDisabled ? "已停用" : "系统保护",
                        statusColor: item.isDisabled ? .gray : .orange,
                        isOn: Binding(get: { !item.isDisabled },
                                      set: { store.setEnabled(item, $0) }),
                        toggleDisabled: !advancedMode)
            }
        }
        .navigationTitle("系统服务")
        .navigationSubtitle("苹果自带的服务，默认只能查看")
        .searchable(text: $search, prompt: "搜索服务，如 Siri、蓝牙…")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: Binding(get: { advancedMode },
                                     set: { if $0 { askAdvanced = true } else { advancedMode = false } })) {
                    Text("高级模式")
                }
                .toggleStyle(.switch)
                Button { showHistory = true } label: { Label("修改记录", systemImage: "clock.arrow.circlepath") }
                Button { confirmRestore = true } label: { Label("恢复默认", systemImage: "arrow.uturn.backward") }
                    .disabled(store.pendingRestores.isEmpty)
            }
        }
        .alert("确定打开高级模式吗？", isPresented: $askAdvanced) {
            Button("我知道风险，打开") { advancedMode = true }
            Button("算了", role: .cancel) {}
        } message: {
            Text("停用系统服务可能让蓝牙、iCloud、聚焦搜索等功能失灵。不确定的服务请不要动。所有修改都会被记录，可以一键恢复。")
        }
        .alert("恢复默认", isPresented: $confirmRestore) {
            Button("恢复") { store.restoreDefaults() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会把通过本软件停用的 \(store.pendingRestores.count) 个服务全部重新启用，可能需要输入密码，重启后完全生效。")
        }
        .sheet(isPresented: $showHistory) { HistoryView() }
        .errorAlert($store.lastError)
    }
}

/// 修改记录
struct HistoryView: View {
    @EnvironmentObject var store: ServicesStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("修改记录").font(.headline)
            if store.history.isEmpty {
                Text("还没有改过任何服务。").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.history) { r in
                    HStack {
                        Image(systemName: r.disabled ? "pause.circle" : "play.circle")
                            .foregroundStyle(r.disabled ? .orange : .green)
                        Text(r.disabled ? "停用了" : "启用了")
                        Text(r.label).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(r.date, style: .date).foregroundStyle(.secondary)
                        Text(r.date, style: .time).foregroundStyle(.secondary)
                    }
                }
            }
            HStack { Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 620, height: 420)
    }
}
