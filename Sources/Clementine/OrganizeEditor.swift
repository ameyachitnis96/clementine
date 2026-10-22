import AppKit
import PDFKit
import SwiftUI

/// Reorder and delete PDF pages.
@MainActor
final class OrganizeModel: ObservableObject {
    let url: URL
    @Published var order: [Int] = []
    @Published var selection = Set<Int>()
    @Published var isWorking = false
    @Published var errorMessage: String?
    private(set) var thumbnails: [Int: NSImage] = [:]

    init(url: URL) {
        self.url = url
        guard let doc = PDFDocument(url: url) else {
            errorMessage = ConversionError.unreadable(url).localizedDescription
            return
        }
        order = Array(0..<doc.pageCount)
        for i in order {
            thumbnails[i] = doc.page(at: i)?.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox)
        }
    }

    func deleteSelected() {
        order.removeAll(where: selection.contains)
        selection = []
    }

    func save(then close: @escaping () -> Void) {
        isWorking = true
        let url = url, order = order
        EditorWindow.export("Organize", file: url, close: close, failed: { self.isWorking = false; self.errorMessage = $0 }) {
            try DocumentConverter.organize(url, order: order)
        }
    }
}

struct OrganizeEditorView: View {
    @ObservedObject var model: OrganizeModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.order, id: \.self) { index in
                    HStack(spacing: 12) {
                        if let thumb = model.thumbnails[index] {
                            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).frame(width: 60, height: 80)
                        }
                        Text("Page \(index + 1)")
                    }
                }
                .onMove { model.order.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { model.order.remove(atOffsets: $0) }
            }
            Divider()
            HStack(spacing: 12) {
                Text("Drag pages to reorder · \(model.order.count) pages").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let message = model.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Button("Delete Page") { model.deleteSelected() }.disabled(model.selection.isEmpty)
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(model.isWorking ? "Saving…" : "Save") { model.save(then: close) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking || model.order.isEmpty)
            }
            .padding(12)
        }
        .tint(.tangerine)
    }
}

@MainActor
enum OrganizeEditor {
    static func open(_ url: URL) {
        let model = OrganizeModel(url: url)
        EditorWindow.present(title: "Organize — \(url.lastPathComponent)", size: CGSize(width: 560, height: 680)) { close in
            OrganizeEditorView(model: model, close: close)
        }
    }
}
