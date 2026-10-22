import AppKit
import AVFoundation
import SwiftUI

/// Hosts one SwiftUI editor in a regular titled window and keeps it alive until closed.
@MainActor
final class EditorWindow: NSObject, NSWindowDelegate {
    private static var open: [EditorWindow] = []
    private let window: NSWindow

    @discardableResult
    static func present<V: View>(title: String, size: CGSize, content: (@escaping () -> Void) -> V) -> EditorWindow {
        let editor = EditorWindow(title: title, size: size)
        editor.window.contentView = NSHostingView(rootView: content { [weak editor] in editor?.window.close() })
        open.append(editor)
        NSApp.activate(ignoringOtherApps: true)
        editor.window.makeKeyAndOrderFront(nil)
        return editor
    }

    private init(title: String, size: CGSize) {
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 520, height: 420)
        window.delegate = self
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }

    /// Runs an editor's save off the main actor: records it in Recent, reveals the result and
    /// closes the editor, or hands the error back so the editor stays open.
    static func export(_ label: String, file: URL, close: @escaping () -> Void, failed: @escaping (String) -> Void,
                       work: @escaping () async throws -> URL) {
        let id = TaskStore.shared.start("\(label) · \(file.lastPathComponent)")
        Task.detached {
            do {
                let out = try await work()
                await MainActor.run {
                    TaskStore.shared.finish(id, output: out)
                    Feedback.done(label)
                    if Settings.shared.revealInFinder { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                    close()
                }
            } catch {
                await MainActor.run {
                    TaskStore.shared.fail(id, error.localizedDescription)
                    failed(error.localizedDescription)
                }
            }
        }
    }
}

extension Color {
    static let tangerine = Color(red: 1.0, green: 0.55, blue: 0.12)
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free", original = "Original", square = "1:1", fourThree = "4:3", sixteenNine = "16:9", nineSixteen = "9:16"
    var id: String { rawValue }

    /// Width / height in pixels, nil when unconstrained.
    func ratio(original: CGSize) -> Double? {
        switch self {
        case .free: return nil
        case .original: return original.width / max(original.height, 1)
        case .square: return 1
        case .fourThree: return 4 / 3
        case .sixteenNine: return 16 / 9
        case .nineSixteen: return 9 / 16
        }
    }
}

/// Crop state for an image or a video frame.
@MainActor
final class CropModel: ObservableObject {
    enum Handle { case topLeft, topRight, bottomLeft, bottomRight, move }

    let url: URL
    let isVideo: Bool
    @Published var preview: NSImage?
    @Published var pixelSize = CGSize(width: 1, height: 1)
    @Published var rect = CropRect.full
    @Published var aspect = CropAspect.free { didSet { applyAspect() } }
    @Published var isWorking = false
    @Published var errorMessage: String?
    private var dragStart: CropRect?

    static let minimumSize = 0.02

    init(url: URL) {
        self.url = url
        isVideo = FormatCompatibilityMatrix.group(for: url) == .video
        Task { await load() }
    }

    private func load() async {
        do {
            let image: CGImage
            if isVideo {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                image = try await generator.image(at: .zero).image
            } else {
                image = try ImageConverter.cgImage(url)
            }
            pixelSize = CGSize(width: image.width, height: image.height)
            preview = NSImage(cgImage: image, size: pixelSize)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var pixelLabel: String {
        let r = rect.pixels(in: pixelSize)
        return "\(Int(r.width)) × \(Int(r.height)) px"
    }

    /// `translation` is in normalized units of the displayed image.
    func drag(_ handle: Handle, translation: CGSize) {
        let start = dragStart ?? rect
        dragStart = start
        let dx = translation.width, dy = translation.height
        let minSize = Self.minimumSize
        var r = start
        switch handle {
        case .move:
            r.x = min(max(0, start.x + dx), 1 - start.width)
            r.y = min(max(0, start.y + dy), 1 - start.height)
        case .topLeft:
            r.x = min(max(0, start.x + dx), start.x + start.width - minSize)
            r.y = min(max(0, start.y + dy), start.y + start.height - minSize)
            r.width = start.x + start.width - r.x
            r.height = start.y + start.height - r.y
        case .topRight:
            r.y = min(max(0, start.y + dy), start.y + start.height - minSize)
            r.width = min(max(minSize, start.width + dx), 1 - start.x)
            r.height = start.y + start.height - r.y
        case .bottomLeft:
            r.x = min(max(0, start.x + dx), start.x + start.width - minSize)
            r.width = start.x + start.width - r.x
            r.height = min(max(minSize, start.height + dy), 1 - start.y)
        case .bottomRight:
            r.width = min(max(minSize, start.width + dx), 1 - start.x)
            r.height = min(max(minSize, start.height + dy), 1 - start.y)
        }
        if handle != .move, let ratio = aspect.ratio(original: pixelSize) {
            r = constrain(r, ratio: ratio, anchor: handle)
        }
        rect = r
    }

    func endDrag() { dragStart = nil }

    func reset() {
        rect = .full
        applyAspect()
    }

    /// Fits the rect to the aspect ratio, keeping the corner opposite `anchor` fixed.
    private func constrain(_ r: CropRect, ratio: Double, anchor: Handle) -> CropRect {
        // height in normalized units for a given normalized width.
        let hFor = { (w: Double) in w * self.pixelSize.width / (ratio * self.pixelSize.height) }
        let wFor = { (h: Double) in h * ratio * self.pixelSize.height / self.pixelSize.width }
        let right = r.x + r.width, bottom = r.y + r.height
        var w = r.width, h = hFor(w)
        // Respect the room available on the side that moves.
        let maxW: Double, maxH: Double
        switch anchor {
        case .topLeft: maxW = right; maxH = bottom
        case .topRight: maxW = 1 - r.x; maxH = bottom
        case .bottomLeft: maxW = right; maxH = 1 - r.y
        default: maxW = 1 - r.x; maxH = 1 - r.y
        }
        if h > maxH { h = maxH; w = wFor(h) }
        if w > maxW { w = maxW; h = hFor(w) }
        switch anchor {
        case .topLeft: return CropRect(x: right - w, y: bottom - h, width: w, height: h)
        case .topRight: return CropRect(x: r.x, y: bottom - h, width: w, height: h)
        case .bottomLeft: return CropRect(x: right - w, y: r.y, width: w, height: h)
        default: return CropRect(x: r.x, y: r.y, width: w, height: h)
        }
    }

    /// Largest centered rect with the selected ratio.
    private func applyAspect() {
        guard let ratio = aspect.ratio(original: pixelSize) else { return }
        var w = 1.0, h = w * pixelSize.width / (ratio * pixelSize.height)
        if h > 1 { h = 1; w = h * ratio * pixelSize.height / pixelSize.width }
        rect = CropRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    func save(then close: @escaping () -> Void) {
        isWorking = true
        let url = url, rect = rect, isVideo = isVideo
        EditorWindow.export("Crop", file: url, close: close, failed: { self.isWorking = false; self.errorMessage = $0 }) {
            isVideo ? try await MediaConverter.crop(url, to: rect) : try ImageConverter.crop(url, to: rect)
        }
    }
}

struct CropEditorView: View {
    @ObservedObject var model: CropModel
    let close: () -> Void

    private let tangerine = Color(red: 1.0, green: 0.55, blue: 0.12)

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let frame = fittedFrame(in: geo.size)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.85)
                    if let preview = model.preview {
                        Image(nsImage: preview)
                            .resizable()
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                        overlay(frame: frame)
                    } else if let message = model.errorMessage {
                        Text(message).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            Divider()
            controls.padding(12)
        }
        .tint(tangerine)
    }

    private func fittedFrame(in size: CGSize) -> CGRect {
        let inset: CGFloat = 24
        let avail = CGSize(width: max(1, size.width - inset * 2), height: max(1, size.height - inset * 2))
        let scale = min(avail.width / model.pixelSize.width, avail.height / model.pixelSize.height)
        let w = model.pixelSize.width * scale, h = model.pixelSize.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    @ViewBuilder
    private func overlay(frame: CGRect) -> some View {
        let r = model.rect
        let sel = CGRect(x: frame.minX + r.x * frame.width, y: frame.minY + r.y * frame.height,
                         width: r.width * frame.width, height: r.height * frame.height)
        // Dim everything outside the selection.
        Path { p in
            p.addRect(frame)
            p.addRect(sel)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)

        // Rule of thirds + border; dragging inside moves the selection.
        Path { p in
            for i in 1...2 {
                let fx = sel.minX + sel.width * CGFloat(i) / 3, fy = sel.minY + sel.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: fx, y: sel.minY)); p.addLine(to: CGPoint(x: fx, y: sel.maxY))
                p.move(to: CGPoint(x: sel.minX, y: fy)); p.addLine(to: CGPoint(x: sel.maxX, y: fy))
            }
        }
        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        .allowsHitTesting(false)

        Rectangle()
            .stroke(Color.white, lineWidth: 1.5)
            .background(Color.white.opacity(0.001))
            .frame(width: sel.width, height: sel.height)
            .offset(x: sel.minX, y: sel.minY)
            .gesture(dragGesture(.move, frame: frame))

        ForEach([CropModel.Handle.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { handle in
            let point = corner(handle, of: sel)
            RoundedRectangle(cornerRadius: 3)
                .fill(tangerine)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1.5))
                .frame(width: 16, height: 16)
                .offset(x: point.x - 8, y: point.y - 8)
                .gesture(dragGesture(handle, frame: frame))
        }
    }

    private func corner(_ handle: CropModel.Handle, of r: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        default: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    private func dragGesture(_ handle: CropModel.Handle, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                model.drag(handle, translation: CGSize(width: value.translation.width / frame.width,
                                                       height: value.translation.height / frame.height))
            }
            .onEnded { _ in model.endDrag() }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Aspect", selection: $model.aspect) {
                ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 380)
            Text(model.pixelLabel).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            if let message = model.errorMessage, model.preview != nil {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            Button("Reset") { model.reset() }
            Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            Button(model.isWorking ? "Cropping…" : "Crop") { model.save(then: close) }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWorking || model.preview == nil)
        }
    }
}

@MainActor
enum CropEditor {
    static func open(_ url: URL) {
        let model = CropModel(url: url)
        EditorWindow.present(title: "Crop — \(url.lastPathComponent)", size: CGSize(width: 900, height: 680)) { close in
            CropEditorView(model: model, close: close)
        }
    }
}
