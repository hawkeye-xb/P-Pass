import PPassCore
import SwiftUI
import UniformTypeIdentifiers

/// #1763 素材文件夹二级页（最小正式入口，首版不做最终 UX）：列表（名称 + 授权/等待状态）、
/// 添加（系统目录选择器授权）、重新授权（等待状态出现）、移除（确认框）。
/// 只复用既有目录来源能力（FolderRegistry / Composite / Flow），不造新传输链；
/// 文案说清边界：只备份文件夹里的照片和视频，移除不删手机素材或桌面已备份内容，不承诺拍完立即同步。
struct FolderSourcesScreen: View {
    @EnvironmentObject var app: AppModel
    @State private var sources: [FolderSourceInfo] = []
    @State private var showingAddPicker = false
    @State private var reauthTarget: FolderSourceInfo?
    @State private var removeTarget: FolderSourceInfo?
    @State private var busy = false

    var body: some View {
        List {
            if sources.isEmpty {
                Section {
                    Text(L.s("folder_sources_empty_body")).font(Self.bodyFont).foregroundStyle(PPColor.ink60)
                }
                .ppTinted(PPUI.Surface.settingsCard)
            }
            ForEach(sources) { source in
                Section { Self.row(source, busy: busy, onReauth: { reauthTarget = source }, onRemove: { removeTarget = source }) }
                    .ppTinted(PPUI.Surface.settingsCard)
            }
            Section {
                Button { showingAddPicker = true } label: {
                    Text(L.s("folder_sources_add")).font(Self.labelFont).foregroundStyle(PPColor.ink)
                }
                .disabled(busy)
                .accessibilityIdentifier("folderSourceAdd")
            }
            .ppTinted(PPUI.Surface.settingsCard)
            Section {
                Text(L.s("folder_sources_footer")).font(Self.hintFont).foregroundStyle(PPColor.ink40)
            }
            .ppTinted(PPUI.Surface.settingsCard)
        }
        .listStyle(.insetGrouped)
        .ppList()
        .navigationTitle(L.s("folder_sources_title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await reload() } }
        .sheet(isPresented: $showingAddPicker) {
            FolderPicker { url in Task { await run("folder-add") { try await app.backend.engine.addFolderSource(at: url, displayName: url.lastPathComponent) } } }
        }
        .sheet(item: $reauthTarget) { target in
            FolderPicker { url in Task { await run("folder-reauth") { try await app.backend.engine.reauthorizeFolderSource(id: target.id, at: url) } } }
        }
        .confirmationDialog(L.s("folder_sources_remove_confirm_title"), isPresented: Binding(
            get: { removeTarget != nil },
            set: { if !$0 { removeTarget = nil }
            })) {
            Button(L.s("folder_sources_remove"), role: .destructive) {
                if let target = removeTarget {
                    removeTarget = nil
                    Task { await remove(target) }
                }
            }
            Button(L.s("cancel"), role: .cancel) { removeTarget = nil }
        } message: { Text(L.s("folder_sources_remove_confirm_body")) }
    }

    /// 一行：目录名 + 授权/等待状态。等待时给「重新授权」（引擎在 SourceUnavailable 等待，授权恢复后才继续）；
    /// 移除常驻（确认框兜着）。探测失败一律按等待显示，不误报「已授权」（卡面验收口径）。
    private static func row(_ source: FolderSourceInfo, busy: Bool, onReauth: @escaping () -> Void, onRemove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(source.displayName).font(labelFont).foregroundStyle(PPColor.ink)
                .accessibilityIdentifier("folderSourceName")
            HStack(spacing: 12) {
                Text(source.available ? L.s("folder_sources_status_ok") : L.s("folder_sources_status_wait"))
                    .font(hintFont)
                    .foregroundStyle(source.available ? PPColor.ink40 : PPColor.act)
                if !source.available {
                    Button(action: onReauth) { Text(L.s("folder_sources_reauth")) }
                        .font(hintFont).foregroundStyle(PPColor.ink).buttonStyle(.borderless)
                        .disabled(busy)
                        .accessibilityIdentifier("folderSourceReauth")
                }
                Spacer(minLength: 8)
                Button(action: onRemove) { Text(L.s("folder_sources_remove")) }
                    .font(hintFont).foregroundStyle(PPColor.ink40).buttonStyle(.borderless)
                    .disabled(busy)
                    .accessibilityIdentifier("folderSourceRemove")
            }
        }
    }

    private func reload() async {
        sources = await app.backend.engine.folderSources()
        app.refreshFolderCount()
    }

    private func remove(_ target: FolderSourceInfo) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        app.backend.engine.removeFolderSource(id: target.id)
        AppLog.log("folder-remove: ok")
        await reload()
    }

    /// 添加 / 重新授权统一执行：互斥、失败提示（沿用全局 notice）、成功后刷新列表与设置行值。
    /// 选择器取消不进这里（Coordinator 只在真的选了目录时回调）。
    private func run(_ what: String, _ op: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await op()
            AppLog.log("\(what): ok")
        } catch {
            AppLog.log("\(what): failed: \(error)")
            app.notice = UserNotice(message: L.s("folder_sources_add_failed"))
        }
        await reload()
    }

    // 行字号同设置行（tokens.json mobile-ui.type，iOS 覆盖为系统文字样式）。
    private static let labelFont = PPFont.sans(PPUI.TextSize.rowLabel)
    private static let hintFont = PPFont.sans(PPUI.TextSize.rowHint, relativeTo: .footnote)
    private static let bodyFont = PPFont.sans(PPUI.TextSize.rowValue, relativeTo: .subheadline)
}

/// #1763 系统目录选择器：授权一个本地目录（含全部子目录）的安全作用域，可保存书签供后续启动恢复
/// （Apple 标准授权模型，ADR §背景 1）。`asCopy: false` = 授权原位置，不复制进 App 容器（占盘 1x 的前提）。
/// 取消不回调（无动作）；选中回调第一个 URL，安全作用域的 start/stop 由调用方配对（LiveBackend.addFolderSource）。
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FolderPicker
        init(_ parent: FolderPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.dismiss()
            if let url = urls.first { parent.onPick(url) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}
