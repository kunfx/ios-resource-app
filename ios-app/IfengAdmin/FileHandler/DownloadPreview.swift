import QuickLook
import SwiftUI
import UIKit

struct DownloadPreview: View {
    let file: DownloadedFile
    @Environment(\.dismiss) private var dismiss
    @State private var action: FileAction?

    var body: some View {
        NavigationStack {
            Group {
                if QLPreviewController.canPreview(file.url as NSURL) { QuickLookFile(url: file.url) }
                else {
                    VStack(spacing: 16) {
                        Image(systemName: "doc").font(.largeTitle)
                        Text(file.url.lastPathComponent)
                        Text("此格式不支持直接预览，可以保存到文件或使用其他应用打开。")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding()
                }
            }
            .navigationTitle("下载文件").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { action = .save } label: { Label("保存到文件", systemImage: "folder") }
                        Button { action = .share } label: { Label("分享或打开", systemImage: "square.and.arrow.up") }
                    } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
            .sheet(item: $action) { item in
                if item == .save { SaveFile(url: file.url) } else { ShareFile(url: file.url) }
            }
        }
    }
}

private enum FileAction: String, Identifiable { case save, share; var id: String { rawValue } }

private struct QuickLookFile: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

private struct SaveFile: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

private struct ShareFile: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
