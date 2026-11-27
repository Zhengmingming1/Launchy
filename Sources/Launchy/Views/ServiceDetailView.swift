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
    /// 上面的 message 是操作失败的报错（不是「已停止」之类的成功提示）
    @State private var messageIsError = false
    @State private var showEditor = false
    /// 程序签名（第三方服务才查，在后台读取）
    @State private var signature: CodeSignature.Result?
    @State private var signatureChecked = false
    /// 等用户确认后再把这份残留配置移到废纸篓
    @State private var pendingTrash: [ServiceItem] = []
    /// 刚拷贝的是哪一行（"全部" 表示整段），用来短暂显示一个对勾
    @State private var copiedField: String?

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
                    if item.programMissing {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("找不到它要运行的程序（\(item.program ?? "")）。多半是软件已经卸载，只留下了这个配置文件。它没法正常运行，可以关掉，也可以把这份残留配置移到废纸篓（会先备份，需要时能从废纸篓或备份里找回来）。",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityElement(children: .combine)
                            if info.editable {
                                Button("移到废纸篓…", role: .destructive) { pendingTrash = [item] }
                                    .disabled(store.isWorking)
                                    .accessibilityHint("会先备份，再移到废纸篓，不会永久删除，也不会动其他自启动项")
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    section("它是做什么的") { Text(info.description) }
                    if info.editable && !item.programMissing && info.program != nil {
                        section("谁做的") { signatureView }
                    }
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
        .onAppear {
            refreshState()
            checkSignature()
        }
        .sheet(isPresented: $showEditor, onDismiss: {
            info = ServiceInfo(item: item)
            store.reload()
            refreshState()
            checkSignature()
        }) {
            ServiceEditView(item: item, info: info)
        }
        .alert(messageIsError ? FriendlyError.alertSummary(message ?? "") : (message ?? ""),
               isPresented: Binding(get: { message != nil },
                                    set: { if !$0 { message = nil; messageIsError = false } })) {
            Button("知道了", role: .cancel) {}
            if messageIsError, let text = message, !FriendlyError.isUserCancel(text) {
                Button("拷贝详情") { ErrorReport.copy(text) }
            }
        }
        .confirmTrashOrphans($pendingTrash, isWorking: store.isWorking) { items in
            store.cleanOrphans(items) { result in
                if result.trashed.contains(where: { $0.id == item.id }) {
                    dismiss()
                } else if let text = store.lastNotice, !text.isEmpty {
                    // 还在这页，用本页的提示框说清楚；清掉 store 里的，避免关掉后再弹一次
                    messageIsError = false
                    message = text
                    store.lastNotice = nil
                }
            }
        }
    }

    // MARK: - 各部分

    private var header: some View {
        HStack(spacing: 14) {
            ServiceIconView(item: item, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.friendlyName).font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text(info.owningAppName.map { "来自：\($0)" } ?? item.scope.title)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.statusText)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                // 光读「已停用」不知道指什么，补上「当前状态」
                .accessibilityLabel("当前状态：\(item.statusText)")
        }
    }

    private var stateView: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow { fieldName("状态"); fieldValue("状态", stateText) }
            GridRow { fieldName("进程号"); fieldValue("进程号", state?.pid.map(String.init) ?? "—") }
            GridRow { fieldName("上次退出码"); fieldValue("上次退出码", state?.lastExitCode ?? "—") }
        }
    }

    @ViewBuilder
    private var signatureView: some View {
        if let signature {
            VStack(alignment: .leading, spacing: 4) {
                Label(signature.title,
                      systemImage: signature.needsAttention ? "exclamationmark.triangle.fill"
                                   : (signatureIsTrusted(signature.kind) ? "checkmark.seal.fill" : "questionmark.circle"))
                    .foregroundStyle(signature.needsAttention ? Color.orange
                                     : (signatureIsTrusted(signature.kind) ? Color.green : Color.secondary))
                    .font(.body.weight(.medium))
                Text(signature.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = signature.notarizationNote {
                    Label(note, systemImage: signature.notarized == true ? "checkmark.shield" : "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if signature.isScript {
                    Text("检查的是它运行的脚本：\((signature.checkedPath as NSString).lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        } else if signatureChecked {
            Text("无法检查（程序路径不完整）").foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在检查签名…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func signatureIsTrusted(_ kind: CodeSignature.Kind) -> Bool {
        switch kind {
        case .apple, .appStore, .developerID: return true
        default: return false
        }
    }

    private func checkSignature() {
        guard info.editable, !item.programMissing else { return }
        let program = info.program, args = info.arguments
        DispatchQueue.global(qos: .userInitiated).async {
            let r = CodeSignature.check(program: program, arguments: args)
            DispatchQueue.main.async {
                signature = r
                signatureChecked = true
            }
        }
    }

    private var stateText: String {
        guard let state else { return "查询中…" }
        if item.isDisabled { return "已停用" }
        if state.running { return "运行中" }
        return state.loaded ? "已加载，当前没在运行" : "没有加载"
    }

    private var techInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(techFields, id: \.name) { field in
                    GridRow {
                        fieldName(field.name)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            mono(field.value, name: field.name)
                            if field.value != "—" {
                                copyButton(name: field.name, value: field.value)
                            }
                        }
                    }
                }
            }
            Button {
                copy(techSummary, as: "全部")
            } label: {
                Label(copiedField == "全部" ? "已拷贝，可以直接粘贴给别人" : "拷贝全部技术信息",
                      systemImage: copiedField == "全部" ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
            .help("把名称、状态、标签、程序和配置文件位置一起拷贝下来，方便发给别人帮忙看")
        }
    }

    /// 技术信息的几行（名称, 值）；没有的值显示「—」
    private struct TechField { let name: String; let value: String }

    private var techFields: [TechField] {
        var rows = [TechField(name: "标签", value: item.label),
                    TechField(name: "程序", value: info.program ?? "—")]
        if info.arguments.count > 1 {
            rows.append(TechField(name: "参数", value: info.arguments.dropFirst().joined(separator: " ")))
        }
        rows.append(TechField(name: "配置文件", value: item.plistURL.path))
        return rows
    }

    /// 一起拷贝时的纯文本：别人一看就知道是哪一项、现在什么状态
    private var techSummary: String {
        var lines = ["名称：\(item.friendlyName)", "状态：\(stateText)"]
        if let code = state?.lastExitCode, !code.isEmpty { lines.append("上次退出码：\(code)") }
        lines += techFields.map { "\($0.name)：\($0.value)" }
        return lines.joined(separator: "\n")
    }

    /// 每行右边的小拷贝按钮，点完短暂变成对勾
    private func copyButton(name: String, value: String) -> some View {
        Button {
            copy(value, as: name)
        } label: {
            Image(systemName: copiedField == name ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copiedField == name ? Color.green : Color.secondary)
                .frame(width: 14)
        }
        .buttonStyle(.borderless)
        .help(copiedField == name ? "已拷贝" : "拷贝\(name)")
        .accessibilityLabel(copiedField == name ? "已拷贝\(name)" : "拷贝\(name)")
    }

    private func copy(_ text: String, as field: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copiedField = field
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedField == field { copiedField = nil }
        }
    }

    private var footer: some View {
        HStack {
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.plistURL]) }
            if info.editable {
                Button("立即运行") { perform({ ServiceEditor.runNow(item) }, ok: "已经让它运行了一次。") }
                    .disabled(item.isDisabled)
                Button("停止") { perform({ ServiceEditor.stop(item) }, ok: "已发送停止信号。如果它设置了常驻，可能会被系统重新拉起。") }
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
            // VoiceOver 可以按「标题」在几段之间跳着听
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// 表格左边的灰色名称：读屏时并进右边的值里一起读，这里不单独读
    private func fieldName(_ name: String) -> some View {
        Text(name).foregroundStyle(.secondary).accessibilityHidden(true)
    }

    /// 表格右边的值，读成「状态：运行中」，不会只听到一个孤零零的数字或「—」
    private func fieldValue(_ name: String, _ value: String) -> some View {
        Text(value).accessibilityLabel("\(name)：\(spoken(value))")
    }

    private func mono(_ s: String, name: String) -> some View {
        Text(s).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            .accessibilityLabel("\(name)：\(spoken(s))")
    }

    /// 「—」读出来没有意义，换成「没有」
    private func spoken(_ value: String) -> String {
        value == "—" ? "没有" : value
    }

    /// 在后台执行（可能会弹密码框），完成后提示结果并刷新状态
    private func perform(_ work: @escaping @Sendable () -> Shell.Result, ok: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = work()
            DispatchQueue.main.async {
                messageIsError = !r.ok
                message = r.ok ? ok : FriendlyError.text(r.output)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refreshState() }
            }
        }
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
        case keep, none, interval, daily
        var id: String { rawValue }
        var title: String {
            switch self {
            case .keep: return "保持原样"
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
    /// 正在保存/恢复（可能在等管理员密码框）
    @State private var isSaving = false
    @State private var backups: [URL] = []

    /// 打开编辑器时的定时设置，用来判断用户有没有动过；没动过就原样保留
    private let originalMode: ScheduleMode
    private let originalMinutes: Int
    private let originalTime: Date
    /// 原配置里的定时比较复杂（多个时间点、按星期/日期），表单无法完整表示
    private let hasComplexCalendar: Bool

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
        let calendar = info.dict["StartCalendarInterval"]
        var complex = false
        if let s = info.startInterval, calendar == nil {
            mode = .interval; minutes = max(1, s / 60)
        } else if let c = calendar as? [String: Any], let h = c["Hour"] as? Int,
                  Set(c.keys).isSubset(of: ["Hour", "Minute"]), info.startInterval == nil {
            mode = .daily
            time = Calendar.current.date(bySettingHour: h, minute: c["Minute"] as? Int ?? 0, second: 0, of: Date()) ?? time
        } else if calendar != nil || info.startInterval != nil {
            // 多个时间点、按星期几等情况：表单里只读显示，保存时不改
            mode = .keep
            complex = true
        }
        originalMode = mode
        originalMinutes = minutes
        originalTime = time
        hasComplexCalendar = complex
        _mode = State(initialValue: mode)
        _intervalMinutes = State(initialValue: minutes)
        _time = State(initialValue: time)
        let raw = (try? String(contentsOf: item.plistURL, encoding: .utf8)) ?? ""
        _rawText = State(initialValue: raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑「\(item.friendlyName)」").font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            if item.scope.needsAdmin || item.scope == .allUsers {
                Label("这个文件在 /Library 下，保存时需要输入管理员密码。", systemImage: "key")
                    .font(.callout).foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
            }

            Form {
                Section {
                    TextField("程序", text: $program)
                    VStack(alignment: .leading) {
                        Text("参数（每行一个）").font(.caption).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        // 多行输入框没有自带名字，读屏只会说「文本」，这里告诉它是什么
                        TextEditor(text: $argumentsText)
                            .font(.system(.callout, design: .monospaced))
                            .frame(height: 60)
                            .accessibilityLabel("参数，每行一个")
                    }
                    Toggle("开机登录时运行", isOn: $runAtLoad)
                    Picker("定时", selection: $mode) {
                        ForEach(ScheduleMode.allCases.filter { $0 != .keep || hasComplexCalendar }) {
                            Text($0.title).tag($0)
                        }
                    }
                    if mode == .keep {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("现在的设置：\(info.whenText)")
                            Text("这个任务的定时比较复杂，表单里没法完整编辑。保持原样就不会改动它；要改的话可以选别的方式，或者用下面的高级编辑。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    } else if mode == .interval {
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
                            .accessibilityLabel("原始配置，plist XML")
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
                .disabled(isSaving)
                .accessibilityHint(backups.isEmpty ? "还没有备份" : "选一份备份，把这项服务的配置换回当时的样子")
                Spacer()
                if isSaving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在保存…").font(.callout).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("保存并生效") { save() }.buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
            Text("保存前会自动备份原文件到 ~/Library/Application Support/Launchy/backups。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 620, height: 640)
        .onAppear { backups = ServiceEditor.backups(for: item) }
        .alert(FriendlyError.alertSummary(error ?? ""),
               isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) {}
            if let text = error, !FriendlyError.isUserCancel(text) {
                Button("拷贝详情") { ErrorReport.copy(text) }
            }
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
        // 原来没有 RunAtLoad 且用户也没打开，就不额外写这个字段
        if runAtLoad != info.runAtLoad || dict["RunAtLoad"] != nil {
            dict["RunAtLoad"] = runAtLoad
        }

        // 定时没动过就原样保留（包括多个 StartCalendarInterval 的情况）
        let scheduleUnchanged = mode == originalMode
            && (mode != .interval || intervalMinutes == originalMinutes)
            && (mode != .daily || sameMinute(time, originalTime))
        if scheduleUnchanged || mode == .keep { return dict }

        dict.removeValue(forKey: "StartInterval")
        dict.removeValue(forKey: "StartCalendarInterval")
        switch mode {
        case .keep, .none: break
        case .interval: dict["StartInterval"] = intervalMinutes * 60
        case .daily:
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            dict["StartCalendarInterval"] = ["Hour": c.hour ?? 0, "Minute": c.minute ?? 0]
        }
        return dict
    }

    private func sameMinute(_ a: Date, _ b: Date) -> Bool {
        let ca = Calendar.current.dateComponents([.hour, .minute], from: a)
        let cb = Calendar.current.dateComponents([.hour, .minute], from: b)
        return ca.hour == cb.hour && ca.minute == cb.minute
    }

    private func save() {
        // 表单内容在主线程里先整理好，真正的写文件、弹密码框、重新加载放到后台
        let item = self.item
        if useRaw {
            let text = rawText
            runInBackground { try ServiceEditor.save(rawText: text, for: item) }
        } else {
            // 先在主线程把字典转成 XML 文本，后台只传字符串，避免跨线程传递非 Sendable 的字典
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: buildDict(), format: .xml, options: 0)
                let text = String(decoding: data, as: UTF8.self)
                runInBackground { try ServiceEditor.save(rawText: text, for: item) }
            } catch {
                self.error = "整理配置时出错了。\n\n" + FriendlyError.text(error.localizedDescription)
            }
        }
    }

    private func restore(_ url: URL) {
        let item = self.item
        runInBackground { try ServiceEditor.apply(url, to: item) }
    }

    /// 在后台执行保存类操作，期间显示转圈、禁用按钮；成功就关闭，失败用大白话提示
    private func runInBackground(_ work: @escaping @Sendable () throws -> Void) {
        guard !isSaving else { return }
        isSaving = true
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String?
            do {
                try work()
            } catch let e as ServiceEditor.EditError {
                message = e.localizedDescription
            } catch {
                message = FriendlyError.text(error.localizedDescription)
            }
            let finalMessage = message
            DispatchQueue.main.async {
                isSaving = false
                if let finalMessage { self.error = finalMessage } else { dismiss() }
            }
        }
    }

    private func backupTitle(_ url: URL) -> String {
        let stamp = url.deletingPathExtension().lastPathComponent.components(separatedBy: "__").last ?? ""
        return "备份于 " + stamp
    }
}
