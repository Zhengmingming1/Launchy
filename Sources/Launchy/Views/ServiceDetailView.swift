import SwiftUI
import AppKit

/// 服务详情：它是做什么的、什么时候运行、运行状态，以及（第三方服务）编辑。
struct ServiceDetailView: View {
    let item: ServiceItem
    @EnvironmentObject var store: ServicesStore
    @Environment(\.dismiss) private var dismiss

    @State private var info: ServiceInfo
    @State private var state: Launchctl.ServiceState?
    @State private var message: String?
    @State private var showEditor = false

    init(item: ServiceItem) {
        self.item = item
        _info = State(initialValue: ServiceInfo(item: item))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("它是做什么的") { Text(info.description) }
                    section("什么时候运行") { Text(info.whenText) }
                    section("运行状态") { stateView }
                    section("技术信息") { techInfo }
                    if !info.editable {
                        Label("这是苹果的系统服务，受 SIP 保护，只能查看。", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer.padding(14)
        }
        .frame(width: 640, height: 600)
        .onAppear(perform: refreshState)
        .sheet(isPresented: $showEditor, onDismiss: {
            info = ServiceInfo(item: item)
            store.reload()
            refreshState()
        }) {
            ServiceEditView(item: item, info: info)
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) {}
        }
    }

    // MARK: - 各部分

    private var header: some View {
        HStack(spacing: 14) {
            ServiceIconView(item: item, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.friendlyName).font(.title2.weight(.bold))
                Text(info.owningAppName.map { "来自：\($0)" } ?? item.scope.title)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.statusText)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }

    private var stateView: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow { Text("状态").foregroundStyle(.secondary); Text(stateText) }
            GridRow { Text("进程号").foregroundStyle(.secondary); Text(state?.pid.map(String.init) ?? "—") }
            GridRow { Text("上次退出码").foregroundStyle(.secondary); Text(state?.lastExitCode ?? "—") }
        }
    }

    private var stateText: String {
        guard let state else { return "查询中…" }
        if item.isDisabled { return "已停用" }
        if state.running { return "运行中" }
        return state.loaded ? "已加载，当前没在运行" : "没有加载"
    }

    private var techInfo: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow { Text("标签").foregroundStyle(.secondary); mono(item.label) }
            GridRow { Text("程序").foregroundStyle(.secondary); mono(info.program ?? "—") }
            if info.arguments.count > 1 {
                GridRow { Text("参数").foregroundStyle(.secondary); mono(info.arguments.dropFirst().joined(separator: " ")) }
            }
            GridRow { Text("配置文件").foregroundStyle(.secondary); mono(item.plistURL.path) }
        }
    }

    private var footer: some View {
        HStack {
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.plistURL]) }
            if info.editable {
                Button("立即运行") { report(ServiceEditor.runNow(item), ok: "已经让它运行了一次。") }
                    .disabled(item.isDisabled)
                Button("停止") { report(ServiceEditor.stop(item), ok: "已发送停止信号。如果它设置了常驻，可能会被系统重新拉起。") }
                    .disabled(state?.running != true)
                Button("编辑…") { showEditor = true }
            }
            Spacer()
            Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - 小工具

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func mono(_ s: String) -> some View {
        Text(s).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
    }

    private func report(_ r: Shell.Result, ok: String) {
        message = r.ok ? ok : "没有成功：\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refreshState() }
    }

    private func refreshState() {
        let domain = item.scope.domain, label = item.label
        DispatchQueue.global().async {
            let s = Launchctl.state(domain: domain, label: label)
            DispatchQueue.main.async { state = s }
        }
    }
}

/// 编辑第三方服务：常用项表单 + 高级的原始 plist 编辑
struct ServiceEditView: View {
    let item: ServiceItem
    let info: ServiceInfo
    @Environment(\.dismiss) private var dismiss

    enum ScheduleMode: String, CaseIterable, Identifiable {
        case none, interval, daily
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "不定时"
            case .interval: return "每隔一段时间"
            case .daily: return "每天固定时间"
            }
        }
    }

    @State private var program: String
    @State private var argumentsText: String
    @State private var runAtLoad: Bool
    @State private var mode: ScheduleMode
    @State private var intervalMinutes: Int
    @State private var time: Date
    @State private var rawText: String
    @State private var useRaw = false
    @State private var error: String?
    @State private var backups: [URL] = []

    init(item: ServiceItem, info: ServiceInfo) {
        self.item = item
        self.info = info
        let args = info.arguments
        _program = State(initialValue: info.program ?? "")
        _argumentsText = State(initialValue: (args.isEmpty ? [] : Array(args.dropFirst())).joined(separator: "\n"))
        _runAtLoad = State(initialValue: info.runAtLoad)
        var mode = ScheduleMode.none
        var minutes = 60
        var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        if let s = info.startInterval { mode = .interval; minutes = max(1, s / 60) }
        else if let c = info.dict["StartCalendarInterval"] as? [String: Any], let h = c["Hour"] as? Int {
            mode = .daily
            time = Calendar.current.date(bySettingHour: h, minute: c["Minute"] as? Int ?? 0, second: 0, of: Date()) ?? time
        }
        _mode = State(initialValue: mode)
        _intervalMinutes = State(initialValue: minutes)
        _time = State(initialValue: time)
        let raw = (try? String(contentsOf: item.plistURL, encoding: .utf8)) ?? ""
        _rawText = State(initialValue: raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑「\(item.friendlyName)」").font(.title3.weight(.bold))
            if item.scope.needsAdmin || item.scope == .allUsers {
                Label("这个文件在 /Library 下，保存时需要输入管理员密码。", systemImage: "key")
                    .font(.callout).foregroundStyle(.orange)
            }

            Form {
                Section {
                    TextField("程序", text: $program)
                    VStack(alignment: .leading) {
                        Text("参数（每行一个）").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $argumentsText)
                            .font(.system(.callout, design: .monospaced))
                            .frame(height: 60)
                    }
                    Toggle("开机登录时运行", isOn: $runAtLoad)
                    Picker("定时", selection: $mode) {
                        ForEach(ScheduleMode.allCases) { Text($0.title).tag($0) }
                    }
                    if mode == .interval {
                        Stepper("每隔 \(intervalMinutes) 分钟", value: $intervalMinutes, in: 1...10080)
                    } else if mode == .daily {
                        DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute)
                    }
                }
                .disabled(useRaw)

                Section("高级") {
                    Toggle("直接编辑原始配置（plist XML）", isOn: $useRaw)
                    if useRaw {
                        TextEditor(text: $rawText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 160)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Menu("从备份恢复") {
                    if backups.isEmpty { Text("还没有备份") }
                    ForEach(backups, id: \.self) { url in
                        Button(backupTitle(url)) { restore(url) }
                    }
                }
                .frame(width: 140)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并生效") { save() }.buttonStyle(.borderedProminent)
            }
            Text("保存前会自动备份原文件到 ~/Library/Application Support/Launchy/backups。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 620, height: 640)
        .onAppear { backups = ServiceEditor.backups(for: item) }
        .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) {}
        }
    }

    /// 把表单内容合并回原字典，保留其他未知字段
    private func buildDict() -> [String: Any] {
        var dict = info.dict
        let args = argumentsText.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if dict["ProgramArguments"] != nil || !args.isEmpty {
            dict["ProgramArguments"] = [program] + args
            dict.removeValue(forKey: "Program")
        } else {
            dict["Program"] = program
        }
        dict["RunAtLoad"] = runAtLoad
        dict.removeValue(forKey: "StartInterval")
        dict.removeValue(forKey: "StartCalendarInterval")
        switch mode {
        case .none: break
        case .interval: dict["StartInterval"] = intervalMinutes * 60
        case .daily:
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            dict["StartCalendarInterval"] = ["Hour": c.hour ?? 0, "Minute": c.minute ?? 0]
        }
        return dict
    }

    private func save() {
        do {
            if useRaw { try ServiceEditor.save(rawText: rawText, for: item) }
            else { try ServiceEditor.save(buildDict(), for: item) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restore(_ url: URL) {
        do {
            try ServiceEditor.apply(url, to: item)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func backupTitle(_ url: URL) -> String {
        let stamp = url.deletingPathExtension().lastPathComponent.components(separatedBy: "__").last ?? ""
        return "备份于 " + stamp
    }
}
