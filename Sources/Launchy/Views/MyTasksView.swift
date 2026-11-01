import SwiftUI
import AppKit

struct MyTasksView: View {
    @EnvironmentObject var store: MyTasksStore
    @State private var search = ""
    @State private var editing: MyTask?
    @State private var creating = false
    @State private var showingLog: MyTask?
    @State private var confirmDelete: MyTask?
    /// 列表里选中的任务（方便用键盘操作：回车修改、删除键删除、空格暂停/恢复）
    @State private var selection: MyTask.ID?

    private var filtered: [MyTask] {
        search.isEmpty ? store.tasks : store.tasks.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.tasks.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(filtered) { task in
                        row(task)
                            .tag(task.id)
                            .accessibilityAction(named: "修改") { editing = task }
                            .accessibilityAction(named: "立即运行一次") { store.runNow(task) }
                            .accessibilityAction(named: "查看运行记录") { showingLog = task }
                            .accessibilityAction(named: "删除") { confirmDelete = task }
                            .optionalAccessibilityAction(if: task.fixIt == .rechoose, named: "重新选择") { editing = task }
                    }
                }
                // 右键菜单 + 主操作：双击或按回车 = 修改（和访达里「回车打开」的习惯一致）
                .contextMenu(forSelectionType: MyTask.ID.self) { ids in
                    if let task = taskIn(ids) {
                        Button("修改…") { editing = task }
                        Button("立即运行一次") { store.runNow(task) }
                        Button("查看运行记录") { showingLog = task }
                        Button(task.isPaused ? "恢复" : "暂停") { store.setPaused(task, !task.isPaused) }
                        Divider()
                        Button("删除…", role: .destructive) { confirmDelete = task }
                    }
                } primaryAction: { ids in
                    if let task = taskIn(ids) { editing = task }
                }
                // 删除键（以及菜单栏「编辑 › 删除」）：先弹确认，不会直接删
                .onDeleteCommand {
                    if let task = selectedTask { confirmDelete = task }
                }
                .spaceToToggle {
                    guard let task = selectedTask else { return false }
                    store.setPaused(task, !task.isPaused)
                    return true
                }
            }
            Text("提示：关掉开关只是暂停任务，不会删除。选中任务后，按回车修改、按空格暂停或恢复、按删除键删除；右键还能立即运行或查看运行记录。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .navigationTitle("我的任务")
        .navigationSubtitle("你自己创建的定时任务和自启动程序")
        .searchable(text: $search, prompt: "搜索任务名称…")
        .toolbar {
            ToolbarItem {
                Button { store.reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Label("新建任务", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $creating) {
            TaskEditorView(task: nil) { store.save($0) }
        }
        .sheet(item: $editing) { task in
            TaskEditorView(task: task) { store.save($0) }
        }
        .sheet(item: $showingLog) { task in
            LogView(title: task.name, text: store.log(for: task))
        }
        .confirmationDialog("确定删除「\(confirmDelete?.name ?? "")」吗？",
                            isPresented: Binding(get: { confirmDelete != nil },
                                                 set: { if !$0 { confirmDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let t = confirmDelete {
                    store.delete(t)
                    if selection == t.id { selection = nil }
                }
            }
        }
        .errorAlert($store.lastError)
    }

    /// 当前选中且还在列表里的任务（任务被删掉或被搜索过滤掉时为 nil，避免误操作看不见的任务）
    private var selectedTask: MyTask? {
        guard let selection else { return nil }
        return filtered.first { $0.id == selection }
    }

    private func taskIn(_ ids: Set<MyTask.ID>) -> MyTask? {
        guard let id = ids.first else { return nil }
        return filtered.first { $0.id == id }
    }

    private func row(_ task: MyTask) -> some View {
        let (status, color): (String, Color) = {
            if task.isPaused { return ("已暂停", .gray) }
            if task.targetMissing { return ("找不到文件", .orange) }
            if task.lastRunFailed { return ("出错了", .orange) }
            return ("已启用", .green)
        }()
        return ItemRow(
            icon: task.action.kind.icon,
            tint: .accentColor,
            title: task.name,
            subtitle: task.summary,
            status: status,
            statusColor: color,
            isOn: Binding(get: { !task.isPaused },
                          set: { store.setPaused(task, !$0) }),
            footnote: task.lastRunText,
            footnoteColor: task.needsAttention ? .orange : .secondary,
            footnoteButton: task.fixIt.map { fix in (fix.title, { perform(fix, on: task) }) }
        )
    }

    /// 「怎么修」按钮：文件丢了就打开修改窗口重新选，运行失败就打开运行记录
    private func perform(_ fix: MyTask.FixIt, on task: MyTask) {
        switch fix {
        case .rechoose: editing = task
        case .viewLog: showingLog = task
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "alarm").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("还没有任务").font(.title3.weight(.semibold))
            Text("比如「每天晚上 9 点备份文件夹」或者「开机自动打开微信」。")
                .foregroundStyle(.secondary)
            Button("新建第一个任务") { creating = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 列表有焦点时按空格执行 action（macOS 14 起可用；更早的系统上什么也不做，用开关或右键即可）。
/// 只在列表本身获得焦点时生效，在搜索框里打空格不受影响。
private struct SpaceToToggle: ViewModifier {
    /// 返回 true 表示处理了这次按键；没选中任务时返回 false，空格照常交给系统
    let action: () -> Bool
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onKeyPress(.space) {
                action() ? .handled : .ignored
            }
        } else {
            content
        }
    }
}

private extension View {
    func spaceToToggle(_ action: @escaping () -> Bool) -> some View {
        modifier(SpaceToToggle(action: action))
    }
}

/// 显示日志的小窗口
struct LogView: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("「\(title)」的运行记录").font(.headline)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            HStack { Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 560, height: 400)
    }
}
