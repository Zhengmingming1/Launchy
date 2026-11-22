import SwiftUI

/// 从备份还原误清理的残留配置：列出清理时留下的备份，确认后再放回原处。
struct RestoreCleanupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let backups: [ServiceEditor.RestorableCleanup]
    let isWorking: Bool
    var message: String? = nil
    let onRestore: (ServiceEditor.RestorableCleanup) -> Void
    @State private var pending: ServiceEditor.RestorableCleanup?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("还原已清理的配置")
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text("这些是清理残留项时留下的备份。还原只会把配置文件放回原处，不会自动开启。更早清理、又没有留下备份记录的，可以到废纸篓里找。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message, !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(message.contains("没能") || message.contains("没有") ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            }

            if backups.isEmpty {
                Text("没有可以还原的备份。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(backups) { item in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            Text("备份于 \(item.friendlyDate) · \(item.scopeTitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 名称和备份时间一次读完，不用分两下
                        .accessibilityElement(children: .combine)
                        Button("还原…") { pending = item }
                            .disabled(isWorking)
                            .accessibilityHint("把「\(item.name)」的配置放回原处，不会自动开启")
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
                .listStyle(.inset)
            }

            HStack {
                if isWorking {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("正在处理")
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .confirmationDialog(
            pending.map { ServiceEditor.restoreConfirmTitle(for: $0) } ?? "还原",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("还原") {
                if let item = pending {
                    onRestore(item)
                }
            }
            .disabled(isWorking)
            Button("取消", role: .cancel) {}
        } message: {
            Text(pending.map { ServiceEditor.restoreConfirmMessage(for: $0) } ?? "")
        }
        .onChange(of: backups.count) { count in
            if count == 0 { dismiss() }
        }
    }
}
