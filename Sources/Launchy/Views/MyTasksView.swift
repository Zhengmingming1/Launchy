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
            let text = store.log(for: task)
            // 只有上次运行失败时才去认错误行，成功的任务不标橙
            LogView(title: task.name, text: text,
                    problem: task.lastRunFailed ? LogDiagnosis.problem(in: text, action: task.action) : nil)
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

/// 显示日志的小窗口。
/// 认出了出错的那一行时：顶部用大白话说明原因，那一行标橙并自动滚过去；
/// 没认出来时自动滚到最底下（最新的输出在最后）。
struct LogView: View {
    let title: String
    let text: String
    var problem: LogDiagnosis.Problem? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private struct Line: Identifiable {
        let id: Int
        let text: String
    }

    private var lines: [Line] {
        text.components(separatedBy: .newlines).enumerated().map { Line(id: $0.offset, text: $0.element) }
    }

    /// 出错的那一行在第几行（同样的错误出现多次时取最后一次，也就是这次运行的）
    private func problemIndex(in lines: [Line]) -> Int? {
        guard let problem else { return nil }
        return lines.last { $0.text.trimmingCharacters(in: .whitespaces) == problem.line }?.id
    }

    var body: some View {
        let lines = self.lines
        let highlighted = problemIndex(in: lines)
        VStack(alignment: .leading, spacing: 12) {
            Text("「\(title)」的运行记录").font(.headline)
            if let problem {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem.hint)
                        if highlighted != nil {
                            Text("出错的那一行已在下面用橙色标出。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .combine)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            logLine(line, isProblem: line.id == highlighted)
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .onAppear {
                    let target = highlighted ?? lines.last?.id
                    guard let target else { return }
                    // 等列表先排好版再滚动
                    DispatchQueue.main.async {
                        proxy.scrollTo(target, anchor: highlighted == nil ? .bottom : .center)
                    }
                }
            }
            HStack {
                Button(copied ? "已拷贝" : "拷贝全部") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .help("把运行记录拷贝下来，方便发给别人帮忙看")
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: problem == nil ? 400 : 460)
    }

    private func logLine(_ line: Line, isProblem: Bool) -> some View {
        // 空行用一个空格占位，保持原来的行距
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(.caption, design: .monospaced))
            .fontWeight(isProblem ? .semibold : .regular)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(isProblem ? Color.orange.opacity(0.25) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 3))
            .overlay(alignment: .leading) {
                if isProblem {
                    Rectangle().fill(Color.orange).frame(width: 3)
                }
            }
            .accessibilityLabel(isProblem ? "出错的一行：\(line.text)" : line.text)
            .id(line.id)
    }
}
