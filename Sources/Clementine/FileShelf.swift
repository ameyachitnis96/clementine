import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// A temporary holding area for files. Drop files in while
/// dragging, collect from several folders, then drag them all out in one go.
@MainActor
final class ShelfModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let url: URL
        var thumbnail: NSImage
        var id: URL { url }
    }

    @Published private(set) var items: [Item] = []
    @Published var isTargeted = false

    var urls: [URL] { items.map(\.url) }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            items.append(Item(url: url, thumbnail: NSWorkspace.shared.icon(forFile: url.path)))
            loadThumbnail(for: url)
        }
    }

    func remove(_ urls: [URL]) {
        items.removeAll { urls.contains($0.url) }
    }

    func clear() { items.removeAll() }

    /// Drops files that were moved or deleted since they were shelved.
    func pruneMissing() {
        items.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private func loadThumbnail(for url: URL) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self, let i = self.items.firstIndex(where: { $0.url == url }) else { return }
                self.items[i].thumbnail = image
            }
        }
    }
}

@MainActor
final class ShelfController {
    static let shared = ShelfController()
    let model = ShelfModel()
    private lazy var panel = ShelfPanel(model: model) { [weak self] in self?.hide() }
    private(set) var isVisible = false

    static let size = CGSize(width: 232, height: 380)

    /// Shows the shelf flush against the edge of the screen containing `point`, centered on it vertically.
    func show(near point: NSPoint? = nil) {
        model.pruneMissing()
        let location = point ?? NSEvent.mouseLocation
        if !isVisible {
            let screen = NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? .zero
            let size = Self.size
            let y = min(max(location.y - size.height / 2, visible.minY), visible.maxY - size.height)
            // Flush with the edge so a drag pushed against it is already over the shelf.
            let x = point == nil ? visible.maxX - size.width - 8 : (screen?.frame.maxX ?? visible.maxX) - size.width
            panel.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
            isVisible = true
        }
    }

    func toggle() { isVisible ? hide() : show() }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        panel.orderOut(nil)
    }

    func add(_ urls: [URL]) {
        model.add(urls)
        show()
    }
}

final class ShelfPanel: NSPanel {
    init(model: ShelfModel, onClose: @escaping () -> Void) {
        super.init(contentRect: CGRect(origin: .zero, size: ShelfController.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: ShelfView(model: model, close: onClose))
    }

    override var canBecomeKey: Bool { true }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    let close: () -> Void

    private let tangerine = Color(red: 1.0, green: 0.55, blue: 0.12)

    var body: some View {
        VStack(spacing: 10) {
            header
            if model.items.isEmpty {
                emptyState
            } else {
                DragAllTile(urls: model.urls, thumbnails: model.items.prefix(3).map(\.thumbnail)) { moved in
                    model.remove(moved)
                }
                .frame(height: 74)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.items) { row($0) }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: ShelfController.size.width, height: ShelfController.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(model.isTargeted ? tangerine : Color.white.opacity(0.25), lineWidth: model.isTargeted ? 2 : 0.5))
        .onDrop(of: [.fileURL], isTargeted: $model.isTargeted) { providers in
            Self.loadURLs(providers) { model.add($0) }
            return true
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "tray.full.fill").foregroundStyle(tangerine)
            Text("Shelf").font(.headline)
            if !model.items.isEmpty {
                Text("\(model.items.count)").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(tangerine.opacity(0.2), in: Capsule())
            }
            Spacer()
            if !model.items.isEmpty {
                Button("Clear") { model.clear() }.buttonStyle(.borderless).font(.caption)
            }
            Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help("Hide shelf")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc").font(.system(size: 30)).foregroundStyle(tangerine)
            Text("Drop files here").font(.callout.bold())
            Text("Collect files from anywhere, then drag them out together.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundStyle(model.isTargeted ? tangerine : Color.secondary.opacity(0.5)))
    }

    private func row(_ item: ShelfModel.Item) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: item.thumbnail).resizable().aspectRatio(contentMode: .fit).frame(width: 28, height: 28)
            Text(item.url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button { model.remove([item.url]) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
            Divider()
            Button("Remove from Shelf") { model.remove([item.url]) }
        }
    }

    static func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                if let url = object as? URL {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { completion(urls) } }
    }
}

/// Stack tile that starts one multi-file drag with every shelved file.
struct DragAllTile: NSViewRepresentable {
    let urls: [URL]
    let thumbnails: [NSImage]
    let onMoved: ([URL]) -> Void

    func makeNSView(context: Context) -> DragAllView {
        let view = DragAllView()
        update(view)
        return view
    }

    func updateNSView(_ view: DragAllView, context: Context) { update(view) }

    private func update(_ view: DragAllView) {
        view.urls = urls
        view.thumbnails = thumbnails
        view.onMoved = onMoved
        view.needsDisplay = true
    }
}

final class DragAllView: NSView, NSDraggingSource {
    var urls: [URL] = []
    var thumbnails: [NSImage] = []
    var onMoved: ([URL]) -> Void = { _ in }
    private var mouseDownPoint: NSPoint?

    private let tangerine = NSColor(red: 1.0, green: 0.55, blue: 0.12, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        tangerine.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        tangerine.withAlphaComponent(0.6).setStroke()
        let border = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12)
        border.lineWidth = 1
        border.stroke()

        // Fanned stack of up to three thumbnails.
        for (i, image) in thumbnails.enumerated().reversed() {
            let rect = NSRect(x: 14 + CGFloat(i) * 9, y: bounds.midY - 24 + CGFloat(i) * 2, width: 44, height: 44)
            image.draw(in: rect)
        }
        let title = "Drag all \(urls.count)" as NSString
        title.draw(at: NSPoint(x: 86, y: bounds.midY + 2),
                   withAttributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        ("⌘-drag to move" as NSString).draw(at: NSPoint(x: 86, y: bounds.midY - 16),
                   withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
    }

    override func mouseDown(with event: NSEvent) { mouseDownPoint = convert(event.locationInWindow, from: nil) }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !urls.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        mouseDownPoint = nil
        let items = urls.enumerated().map { i, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = NSWorkspace.shared.icon(forFile: url.path)
            item.setDraggingFrame(NSRect(x: start.x - 24 + CGFloat(i) * 4, y: start.y - 24 - CGFloat(i) * 4, width: 48, height: 48),
                                  contents: image)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .stack
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic, .link] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Finder moves on ⌘-drag (or across folders on the same volume); drop those from the shelf.
        if operation == .move {
            let moved = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
            onMoved(moved.isEmpty ? urls : moved)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
