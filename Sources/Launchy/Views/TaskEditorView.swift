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
    private var canSave: Bool { saveBlockedStep == nil }
    /// 还差哪一步才能保存（nil 表示可以保存）。按钮旁的小字和读屏提示共用这一句。
    private var saveBlockedStep: String? {
        if path.isEmpty { return "先在「做什么」下面点「选择…」选一个文件" }
        if scheduleKind == .every && amount <= 0 { return "间隔要大于 0，比如每隔 30 分钟" }
        return nil
    }
    /// 为什么现在还不能保存（读屏用户看不到按钮变灰，要说出来）
    private var saveBlockedReason: String? { saveBlockedStep.map { "还不能保存：\($0)" } }
    /// 间隔太短时的温和提醒（不阻止保存）。少于 5 分钟很容易刷屏或费电。
    private var shortIntervalNote: String? {
        guard scheduleKind == .every, !unitIsHour, amount > 0, amount < 5 else { return nil }
        let every = amount == 1 ? "每分钟" : "每隔 \(amount) 分钟"
        switch actionKind {
        case .openApp:
            return "\(every)打开一次有点频繁：程序会一次次跳到最前面，关掉后也很快又会自己弹出来。如果只是想让它一直开着，选「开机时」就够了。"
        case .openFile:
            return "\(every)打开一次有点频繁：文件会一次次弹到最前面，可能打断你手上的事。没有特别需要的话，建议 5 分钟以上。"
        case .runScript:
            return "\(every)运行一次有点频繁，会让电脑更费电；脚本还没跑完时，下一次会被跳过。没有特别需要的话，建议 5 分钟以上。"
        }
    }
    /// 选中的文件已经找不到了（例如修改一个旧任务，而程序已被移走）
    private var pathMissing: Bool { !path.isEmpty && ServiceItem.isProgramMissing(path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "新建任务" : "修改任务").font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)

            Text("给任务起个名字").font(.headline)
                .accessibilityAddTraits(.isHeader)
            TextField("比如：清理下载文件夹", text: $name)
                .textFieldStyle(.roundedBorder)
                // 占位文字会随输入消失，VoiceOver 需要一个固定的名字
                .accessibilityLabel("任务名字")
                .accessibilityHint("可以不填，不填就用所选文件的名字")

            Text("① 做什么？").font(.headline)
                .accessibilityAddTraits(.isHeader)
            ChoiceRow(options: TaskAction.Kind.allCases, selection: $actionKind,
                      title: { $0.title }, icon: { $0.icon }, groupName: "做什么")
            HStack {
                Image(systemName: "folder")
                    .accessibilityHidden(true)
                Text(path.isEmpty ? "还没有选择" : (path as NSString).lastPathComponent)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityLabel(path.isEmpty
                        ? "还没有选择\(actionKind.title)要用的文件"
                        : "已选择：\((path as NSString).lastPathComponent)\(pathMissing ? "，但现在找不到它了" : "")")
                Spacer()
                Button("选择…", action: choosePath)
                    .accessibilityLabel(path.isEmpty ? "选择文件" : "重新选择文件")
                    .accessibilityHint("打开选择窗口，挑一个\(actionKind.title)要用的文件")
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
                .accessibilityAddTraits(.isHeader)
            ChoiceRow(options: TaskSchedule.Kind.allCases, selection: $scheduleKind,
                      title: { $0.title }, icon: { $0.icon }, groupName: "什么时候做")
            scheduleDetail
            // 间隔太短时温和提醒一句，仍然可以保存
            if let note = shortIntervalNote {
                Label(note, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .accessibilityLabel("提醒：\(note)")
            }

            // 一句话总结，让人一眼看懂
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(TaskSummary.make(action: action, schedule: schedule))
                    // 告诉用户保存后什么时候第一次运行，免得以为「建好了没反应」
                    Text(original?.isPaused == true
                         ? "这个任务现在是暂停的，打开开关恢复后才会按计划运行。"
                         : schedule.firstRunPreview())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                // 总结和第一次运行的说明合成一句读出
                .accessibilityElement(children: .combine)

            HStack {
                // 按钮变灰时，在旁边直接写出还差哪一步，不让人对着灰按钮猜
                if let step = saveBlockedStep {
                    Label("还差一步：\(step)", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                        // 读屏会在「创建任务」按钮的提示里说出同一句，这里不重复念
                        .accessibilityHidden(true)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? "创建任务" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .accessibilityHint(saveBlockedReason ?? "")
            }
            .animation(.easeInOut(duration: 0.15), value: saveBlockedStep)
        }
        .animation(.easeInOut(duration: 0.15), value: shortIntervalNote)
        .padding(24)
        .frame(width: 600)
        .onChange(of: actionKind) { _ in path = "" } // 换了类型，之前选的路径多半不适用
    }

    @ViewBuilder private var scheduleDetail: some View {
        switch scheduleKind {
        case .every:
            HStack {
                Text("每隔")
                    .accessibilityHidden(true)
                TextField("", value: $amount, format: .number)
                    .frame(width: 60).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("每隔多少\(unitIsHour ? "小时" : "分钟")运行一次")
                Picker("", selection: $unitIsHour) {
                    Text("分钟").tag(false)
                    Text("小时").tag(true)
                }
                .labelsHidden().frame(width: 80)
                .accessibilityLabel("间隔单位")
                Text("运行一次")
                    .accessibilityHidden(true)
            }
        case .daily:
            DatePicker("每天的", selection: $time, displayedComponents: .hourAndMinute)
                .frame(width: 200)
                .accessibilityLabel("每天运行的时间")
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
    /// 给读屏用的分组名，例如「做什么」
    var groupName: String = ""

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
                // 选中状态只靠颜色区分，读屏要单独说出「已选择」
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityHint(on ? "" : "选择「\(title(option))」")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(groupName)
    }
}
