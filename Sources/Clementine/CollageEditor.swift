import AppKit
import SwiftUI

enum CollageLayout: String, CaseIterable, Identifiable {
    case grid = "Grid", row = "Row", column = "Column", featured = "Featured"
    var id: String { rawValue }
}

enum Collage {
    /// Canvas size and cell frames (top-left origin) for `count` images in square cells of side `cell`.
    /// Featured: the first image spans the top at 16:9, the rest sit in a row below.
    static func layout(_ layout: CollageLayout, count: Int, cell: CGFloat) -> (canvas: CGSize, frames: [CGRect]) {
        let gap = (cell * 0.04).rounded()
        func cells(cols: Int, rows: Int, top: CGFloat) -> [CGRect] {
            (0..<(cols * rows)).map { i in
                CGRect(x: gap + CGFloat(i % cols) * (cell + gap), y: top + CGFloat(i / cols) * (cell + gap), width: cell, height: cell)
            }
        }
        let width = { (cols: Int) in CGFloat(cols) * (cell + gap) + gap }
        if layout == .featured, count > 1 {
            let cols = max(2, count - 1)
            let hero = CGRect(x: gap, y: gap, width: width(cols) - gap * 2, height: ((width(cols) - gap * 2) * 9 / 16).rounded())
            return (CGSize(width: width(cols), height: hero.maxY + gap + cell + gap),
                    [hero] + cells(cols: count - 1, rows: 1, top: hero.maxY + gap))
        }
        let cols = layout == .row ? count : layout == .column ? 1 : Int(Double(count).squareRoot().rounded(.up))
        let rows = Int((Double(count) / Double(max(cols, 1))).rounded(.up))
        return (CGSize(width: width(cols), height: CGFloat(rows) * (cell + gap) + gap),
                Array(cells(cols: cols, rows: rows, top: gap).prefix(count)))
    }

    /// Each image fills its cell (center-cropped) on white.
    static func render(_ images: [CGImage], layout: CollageLayout, cell: CGFloat) -> CGImage? {
        let (canvas, frames) = Self.layout(layout, count: images.count, cell: cell)
        guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: canvas))
        for (image, frame) in zip(images, frames) {
            let cellRect = CGRect(x: frame.minX, y: canvas.height - frame.maxY, width: frame.width, height: frame.height) // CG is bottom-left
            ctx.saveGState()
            ctx.clip(to: cellRect)
            ctx.draw(image, in: cellRect.aspectFill(CGSize(width: image.width, height: image.height)))
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}

@MainActor
final class CollageModel: ObservableObject {
    let urls: [URL]
    @Published var layout = CollageLayout.grid { didSet { refresh() } }
    @Published var preview: NSImage?
    @Published var isWorking = false
    @Published var errorMessage: String?
    private var images: [CGImage] = []

    init(urls: [URL]) {
        self.urls = urls.sortedByName
        do {
            images = try self.urls.map { try ImageConverter.cgImage($0, maxSide: 1600) }
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refresh() {
        guard let cg = Collage.render(images, layout: layout, cell: 240) else { return }
        preview = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }

    func save(then close: @escaping () -> Void) {
        isWorking = true
        let images = images, layout = layout, first = urls[0]
        EditorWindow.export("Collage", file: first, close: close, failed: { self.isWorking = false; self.errorMessage = $0 }) {
            guard let cg = Collage.render(images, layout: layout, cell: 800) else { throw ConversionError.failed("Could not build collage.") }
            let out = OutputPlacement.uniqueURL(in: Settings.shared.outputFolder ?? first.deletingLastPathComponent(), base: "Collage", ext: "png")
            try ImageConverter.write(cg, to: out, type: "png", quality: 1)
            return out
        }
    }
}

struct CollageEditorView: View {
    @ObservedObject var model: CollageModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.85)
                if let preview = model.preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit).padding(24)
                } else if let message = model.errorMessage {
                    Text(message).foregroundStyle(.white)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Picker("Layout", selection: $model.layout) {
                    ForEach(CollageLayout.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
                Text("\(model.urls.count) images").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let message = model.errorMessage, model.preview != nil {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(model.isWorking ? "Saving…" : "Save") { model.save(then: close) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking || model.preview == nil)
            }
            .padding(12)
        }
        .tint(.tangerine)
    }
}

@MainActor
enum CollageEditor {
    static func open(_ urls: [URL]) {
        let model = CollageModel(urls: urls)
        EditorWindow.present(title: "Collage — \(urls.count) images", size: CGSize(width: 900, height: 680)) { close in
            CollageEditorView(model: model, close: close)
        }
    }
}
