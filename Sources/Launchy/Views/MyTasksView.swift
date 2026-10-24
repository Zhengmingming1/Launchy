import SwiftUI
import AppKit

struct MyTasksView: View {
    @EnvironmentObject var store: MyTasksStore
    @State private var search = ""
    @State private var editing: MyTask?
    @State private var creating = false
    @State private var showingLog: MyTask?
    @State private var confirmDelete: MyTask?

    private var filtered: [MyTask] {
        search.isEmpty ? store.tasks : store.tasks.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.tasks.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(filtered) { task in
                        row(task)
                            .contextMenu {
                                Button("修改…") { editing = task }
                                Button("立即运行一次") { store.runNow(task) }
                                Button("查看运行记录") { showingLog = task }
                                Divider()
                                Button("删除", role: .destructive) { confirmDelete = task }
                            }
                            .onTapGesture(count: 2) { editing = task }
                            .accessibilityAction(named: "修改") { editing = task }
                            .accessibilityAction(named: "立即运行一次") { store.runNow(task) }
                            .accessibilityAction(named: "查看运行记录") { showingLog = task }
                            .accessibilityAction(named: "删除") { confirmDelete = task }
                    }
                }
            }
            Text("提示：关掉开关只是暂停任务，不会删除。右键可以修改、删除或查看运行记录。")
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
                if let t = confirmDelete { store.delete(t) }
            }
        }
        .errorAlert($store.lastError)
    }

    private func row(_ task: MyTask) -> some View {
        let (status, color): (String, Color) = {
            if task.isPaused { return ("已暂停", .gray) }
            if let code = task.lastExitStatus, code != 0 { return ("出错了", .orange) }
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
                          set: { store.setPaused(task, !$0) })
        )
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
