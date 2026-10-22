import AppKit
import SwiftUI

enum AnnotationKind: String, CaseIterable, Identifiable {
    case arrow = "Arrow", box = "Box", oval = "Oval", text = "Text", number = "Number"
    var id: String { rawValue }
}

/// One mark in normalized coordinates (0...1, top-left origin) so preview and output match.
struct Annotation {
    var kind: AnnotationKind
    var start: CGPoint
    var end: CGPoint
    var color: CGColor
    var text = ""
}

enum Annotator {
    /// Draws `items` into a top-left-origin context of `size`: the preview canvas or the full image.
    /// Stroke and text sizes scale with the image so both look the same.
    static func draw(_ items: [Annotation], in cg: CGContext, size: CGSize) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let line = max(2, max(size.width, size.height) / 250)
        var number = 0
        for item in items {
            let a = CGPoint(x: item.start.x * size.width, y: item.start.y * size.height)
            let b = CGPoint(x: item.end.x * size.width, y: item.end.y * size.height)
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            let color = NSColor(cgColor: item.color) ?? .systemRed
            cg.setStrokeColor(item.color)
            cg.setFillColor(item.color)
            cg.setLineWidth(line)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            switch item.kind {
            case .box:
                cg.stroke(rect)
            case .oval:
                cg.strokeEllipse(in: rect)
            case .arrow:
                let angle = atan2(b.y - a.y, b.x - a.x), head = line * 5
                cg.strokeLineSegments(between: [a, b])
                cg.move(to: b)
                cg.addLine(to: CGPoint(x: b.x - head * cos(angle - .pi / 6), y: b.y - head * sin(angle - .pi / 6)))
                cg.addLine(to: CGPoint(x: b.x - head * cos(angle + .pi / 6), y: b.y - head * sin(angle + .pi / 6)))
                cg.closePath()
                cg.fillPath()
            case .text:
                NSAttributedString(string: item.text, attributes: [.font: NSFont.boldSystemFont(ofSize: line * 9),
                                                                    .foregroundColor: color]).draw(at: a)
            case .number:
                number += 1
                let r = line * 6
                cg.fillEllipse(in: CGRect(x: a.x - r, y: a.y - r, width: r * 2, height: r * 2))
                let label = NSAttributedString(string: "\(number)", attributes: [.font: NSFont.boldSystemFont(ofSize: r * 1.1),
                                                                                  .foregroundColor: NSColor.white])
                let s = label.size()
                label.draw(at: CGPoint(x: a.x - s.width / 2, y: a.y - s.height / 2))
            }
        }
    }

    static func render(_ url: URL, _ items: [Annotation]) throws -> URL {
        let image = try ImageConverter.cgImage(url)
        let size = CGSize(width: image.width, height: image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.failed("Could not annotate image.")
        }
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(items, in: ctx, size: size)
        guard let annotated = ctx.makeImage() else { throw ConversionError.failed("Could not annotate image.") }
        let ext = ImageConverter.writableExt(url)
        let out = OutputPlacement.destination(for: url, ext: ext, suffix: " annotated")
        try ImageConverter.write(annotated, to: out, type: ext, quality: Settings.shared.quality)
        return out
    }
}

@MainActor
final class AnnotateModel: ObservableObject {
    let url: URL
    @Published var preview: NSImage?
    @Published var items: [Annotation] = []
    @Published var kind = AnnotationKind.arrow
    @Published var color = CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
    @Published var text = "Text"
    @Published var isWorking = false
    @Published var errorMessage: String?
    private var drawing = false

    init(url: URL) {
        self.url = url
        do {
            let cg = try ImageConverter.cgImage(url, maxSide: 2000)
            preview = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Points are normalized. The first call of a drag adds a mark, later calls move its end.
    func drag(from start: CGPoint, to end: CGPoint) {
        if drawing {
            items[items.count - 1].end = end
        } else {
            items.append(Annotation(kind: kind, start: start, end: end, color: color, text: text))
            drawing = true
        }
    }

    func endDrag() { drawing = false }
    func undo() { _ = items.popLast() }

    func save(then close: @escaping () -> Void) {
        isWorking = true
        let url = url, items = items
        EditorWindow.export("Annotate", file: url, close: close, failed: { self.isWorking = false; self.errorMessage = $0 }) {
            try Annotator.render(url, items)
        }
    }
}

struct AnnotateEditorView: View {
    @ObservedObject var model: AnnotateModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.85)
                    if let preview = model.preview {
                        let frame = fitted(preview.size, in: geo.size)
                        ZStack {
                            Image(nsImage: preview).resizable()
                            Canvas { ctx, size in
                                ctx.withCGContext { Annotator.draw(model.items, in: $0, size: size) }
                            }
                        }
                        .frame(width: frame.width, height: frame.height)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { model.drag(from: normalize($0.startLocation, frame), to: normalize($0.location, frame)) }
                            .onEnded { _ in model.endDrag() })
                    } else if let message = model.errorMessage {
                        Text(message).foregroundStyle(.white)
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Picker("Tool", selection: $model.kind) {
                    ForEach(AnnotationKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                ColorPicker("Color", selection: $model.color)
                if model.kind == .text { TextField("Text", text: $model.text).frame(width: 140) }
                Button("Undo") { model.undo() }.keyboardShortcut("z").disabled(model.items.isEmpty)
                Spacer()
                if let message = model.errorMessage, model.preview != nil {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(model.isWorking ? "Saving…" : "Save") { model.save(then: close) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking || model.items.isEmpty)
            }
            .padding(12)
        }
        .tint(.tangerine)
    }

    private func fitted(_ image: CGSize, in size: CGSize) -> CGSize {
        let scale = min((size.width - 48) / max(image.width, 1), (size.height - 48) / max(image.height, 1))
        return CGSize(width: max(1, image.width * scale), height: max(1, image.height * scale))
    }

    private func normalize(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, p.x / size.width), 1), y: min(max(0, p.y / size.height), 1))
    }
}

@MainActor
enum AnnotateEditor {
    static func open(_ url: URL) {
        let model = AnnotateModel(url: url)
        EditorWindow.present(title: "Annotate — \(url.lastPathComponent)", size: CGSize(width: 960, height: 700)) { close in
            AnnotateEditorView(model: model, close: close)
        }
    }
}
