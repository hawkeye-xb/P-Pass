import SwiftUI
import UniformTypeIdentifiers

/// 系统目录选择器：授权一个本地目录（含全部子目录）的安全作用域，可保存书签供后续启动恢复。
/// `asCopy: false` = 授权原位置，不复制进 App 容器（占盘 1x 的前提）。
/// 取消不回调（无动作）；选中回调第一个 URL，安全作用域的 start/stop 由调用方配对。
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
