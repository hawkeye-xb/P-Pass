import PPassCore
import SwiftUI
import UniformTypeIdentifiers

/// 单次从系统文件选择具体照片或视频；只返回选中的 URL，不登记目录授权。
struct SingleTransferFilePicker: UIViewControllerRepresentable {
    typealias Item = (fileName: String, mimeType: String, payload: PickedPayload)

    let onPicked: ([Item]) -> Void
    @Environment(\.dismiss) private var dismiss

    static func items(from urls: [URL]) -> [Item] {
        urls.enumerated().compactMap { index, url in
            FilePickedPayload.describe(url, index: index).map {
                (fileName: $0.name, mimeType: $0.mime, payload: $0.payload)
            }
        }
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image, .movie], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: SingleTransferFilePicker
        init(_ parent: SingleTransferFilePicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.dismiss()
            let items = SingleTransferFilePicker.items(from: urls)
            if !items.isEmpty { parent.onPicked(items) }
        }
    }
}
