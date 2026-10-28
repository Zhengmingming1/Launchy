import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 「新建任务 / 修改任务」弹窗。尽量只问两个问题：做什么？什么时候做？
struct TaskEditorView: View {
    let original: MyTask?
    let onSave: (MyTask) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var actionKind: TaskAction.Kind
    @State private var path: String
    @State private var scheduleKind: TaskSchedule.Kind
    @State private var amount: Int
    @State private var unitIsHour: Bool
    @State private var time: Date

    init(task: MyTask?, onSave: @escaping (MyTask) -> Void) {
        self.original = task
        self.onSave = onSave
        _name = State(initialValue: task?.name ?? "")
        _actionKind = State(initialValue: task?.action.kind ?? .openApp)
        _path = State(initialValue: task?.action.path ?? "")
        _scheduleKind = State(initialValue: task?.schedule.kind ?? .every)

        var amount = 60, hour = false
        var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        switch task?.schedule {
        case .every(let m)?:
            if m % 60 == 0 { amount = m / 60; hour = true } else { amount = m }
        case .daily(let h, let m)?:
            time = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? time
        default: break
        }
        _amount = State(initialValue: amount)
        _unitIsHour = State(initialValue: hour)
        _time = State(initialValue: time)
    }

    /// 根据当前选择拼出来的计划
    private var schedule: TaskSchedule {
        switch scheduleKind {
        case .every:
            return .every(minutes: max(1, amount) * (unitIsHour ? 60 : 1))
        case .daily:
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            return .daily(hour: c.hour ?? 0, minute: c.minute ?? 0)
        case .atLogin:
            return .atLogin
        }
    }

    private var action: TaskAction { .make(actionKind, path: path) }
    private var canSave: Bool { !path.isEmpty && amount > 0 }
    /// 选中的文件已经找不到了（例如修改一个旧任务，而程序已被移走）
    private var pathMissing: Bool { !path.isEmpty && ServiceItem.isProgramMissing(path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "新建任务" : "修改任务").font(.title2.weight(.bold))

            Text("给任务起个名字").font(.headline)
            TextField("比如：清理下载文件夹", text: $name)
                .textFieldStyle(.roundedBorder)

            Text("① 做什么？").font(.headline)
            ChoiceRow(options: TaskAction.Kind.allCases, selection: $actionKind,
                      title: { $0.title }, icon: { $0.icon })
            HStack {
                Image(systemName: "folder")
                Text(path.isEmpty ? "还没有选择" : (path as NSString).lastPathComponent)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("选择…", action: choosePath)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6)
                .stroke(pathMissing ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.quaternary)))
            if pathMissing {
                Label("找不到「\((path as NSString).lastPathComponent)」了，它可能被移走或删除。请点「选择…」重新选一个，不然任务到时候会运行失败。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("② 什么时候做？").font(.headline)
            ChoiceRow(options: TaskSchedule.Kind.allCases, selection: $scheduleKind,
                      title: { $0.title }, icon: { $0.icon })
            scheduleDetail

            // 一句话总结，让人一眼看懂
            Label(TaskSummary.make(action: action, schedule: schedule), systemImage: "checkmark.circle.fill")
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? "创建任务" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 600)
        .onChange(of: actionKind) { _ in path = "" } // 换了类型，之前选的路径多半不适用
    }

    @ViewBuilder private var scheduleDetail: some View {
        switch scheduleKind {
        case .every:
            HStack {
                Text("每隔")
                TextField("", value: $amount, format: .number)
                    .frame(width: 60).textFieldStyle(.roundedBorder)
                Picker("", selection: $unitIsHour) {
                    Text("分钟").tag(false)
                    Text("小时").tag(true)
                }
                .labelsHidden().frame(width: 80)
                Text("运行一次")
            }
        case .daily:
            DatePicker("每天的", selection: $time, displayedComponents: .hourAndMinute)
                .frame(width: 200)
        case .atLogin:
            Text("每次开机、登录到桌面后运行一次。").foregroundStyle(.secondary)
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = actionKind == .openFile
        panel.allowsMultipleSelection = false
        switch actionKind {
        case .openApp:
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
        case .runScript:
            panel.message = "选择一个脚本文件（如 .sh）"
        case .openFile:
            break
        }
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        }
    }

    private func save() {
        var task = original ?? MyTask(name: "", action: action, schedule: schedule)
        task.name = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? (path as NSString).lastPathComponent : name
        task.action = action
        task.schedule = schedule
        onSave(task)
        dismiss()
    }
}

/// 三选一的大按钮
struct ChoiceRow<T: Hashable & Identifiable>: View {
    let options: [T]
    @Binding var selection: T
    let title: (T) -> String
    let icon: (T) -> String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options) { option in
                let on = option == selection
                Button { selection = option } label: {
                    Label(title(option), systemImage: icon(option))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(on ? Color.accentColor : .primary)
                        .background(on ? Color.accentColor.opacity(0.1) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(on ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
