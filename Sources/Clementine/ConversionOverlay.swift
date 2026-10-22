import AppKit
import SwiftUI

/// State shared between the drop-target view and the SwiftUI fan.
@MainActor
final class FanModel: ObservableObject {
    @Published var mode: DragGestureMonitor.Mode = .convert
    @Published var items: [FanAction] = []
    @Published var hovered: Int?
    @Published var subtitle = ""
    @Published var theme: FanTheme = .glass

    static let innerRadius: CGFloat = 62
    static let outerRadius: CGFloat = 178
    static let size: CGFloat = 400

    /// Petal index under `point` (view coordinates, origin bottom-left), or nil for the cancel hub.
    func index(at point: CGPoint) -> Int? {
        let center = CGPoint(x: Self.size / 2, y: Self.size / 2)
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance > Self.innerRadius, distance < Self.outerRadius + 30, !items.isEmpty else { return nil }
        // Angle measured clockwise from 12 o'clock, matching how petals are drawn.
        var angle = atan2(dx, dy)
        if angle < 0 { angle += 2 * .pi }
        let slice = 2 * .pi / CGFloat(items.count)
        return Int((angle + slice / 2).truncatingRemainder(dividingBy: 2 * .pi) / slice)
    }
}

@MainActor
final class ConversionOverlayController {
    private let model = FanModel()
    private lazy var panel = ConversionOverlayPanel(model: model) { [weak self] in self?.hide() }
    private var currentURLs: [URL] = []
    private var isVisible = false

    func show(mode: DragGestureMonitor.Mode, urls: [URL], at point: NSPoint) {
        if isVisible, mode == model.mode, urls == currentURLs { return }
        currentURLs = urls
        model.mode = mode
        model.theme = Settings.shared.theme
        model.hovered = nil
        switch mode {
        case .convert:
            let sets = urls.map { Set(FormatCompatibilityMatrix.outputs(for: $0)) }
            let common = sets.dropFirst().reduce(sets.first ?? []) { $0.intersection($1) }
            let ordered = FormatCompatibilityMatrix.outputs(for: urls[0]).filter(common.contains)
            model.items = ordered.map(FanAction.convert)
        case .tools:
            model.items = FileTool.tools(for: urls).map(FanAction.tool)
        case .actions:
            model.items = FileTool.fileActions.map(FanAction.tool)
        }
        model.subtitle = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        guard !model.items.isEmpty else { hide(); return }

        if !isVisible {
            let size = FanModel.size
            var origin = NSPoint(x: point.x - size / 2, y: point.y - size / 2)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
                let frame = screen.frame
                origin.x = min(max(origin.x, frame.minX), frame.maxX - size)
                origin.y = min(max(origin.y, frame.minY), frame.maxY - size)
            }
            panel.setFrameOrigin(origin)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
            isVisible = true
        }
    }

    func dragEnded() {
        // Let a pending performDragOperation land before tearing down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.hide() }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        panel.orderOut(nil)
        model.hovered = nil
    }
}

/// Borderless, non-activating panel that floats above every app and accepts file drops.
final class ConversionOverlayPanel: NSPanel {
    init(model: FanModel, onFinish: @escaping () -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: FanModel.size, height: FanModel.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        let drop = FanDropView(model: model, onFinish: onFinish)
        drop.frame = NSRect(x: 0, y: 0, width: FanModel.size, height: FanModel.size)
        let host = NSHostingView(rootView: FanView(model: model))
        host.frame = drop.bounds
        host.autoresizingMask = [.width, .height]
        drop.addSubview(host)
        contentView = drop
    }

    override var canBecomeKey: Bool { false }
}

/// Transparent drop target covering the fan. Hit-tests petals by angle.
final class FanDropView: NSView {
    private let model: FanModel
    private let onFinish: () -> Void

    init(model: FanModel, onFinish: @escaping () -> Void) {
        self.model = model
        self.onFinish = onFinish
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { model.hovered = nil }
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        return MainActor.assumeIsolated {
            let index = model.index(at: point)
            if index != model.hovered {
                model.hovered = index
                if index != nil, Settings.shared.playSound { NSSound(named: "Tink")?.play() }
            }
            return index == nil ? [] : .copy
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return MainActor.assumeIsolated {
            defer { onFinish() }
            guard let index = model.index(at: point), model.items.indices.contains(index), !urls.isEmpty else { return false }
            ActionRunner.run(model.items[index], on: urls)
            return true
        }
    }
}

// MARK: - SwiftUI fan

struct PetalShape: Shape {
    let index: Int
    let count: Int
    let inner: CGFloat
    let outer: CGFloat
    let gap: Double = 2.2

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let slice = 360.0 / Double(count)
        // SwiftUI angles: 0° = 3 o'clock, clockwise in a flipped (top-left origin) space.
        let mid = -90 + slice * Double(index)
        let start = Angle.degrees(mid - slice / 2 + gap / 2)
        let end = Angle.degrees(mid + slice / 2 - gap / 2)
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

struct FanView: View {
    @ObservedObject var model: FanModel

    private let tangerine = Color(red: 1.0, green: 0.55, blue: 0.12)

    var body: some View {
        ZStack {
            ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                petal(index: index, item: item)
            }
            hub
        }
        .frame(width: FanModel.size, height: FanModel.size)
        .animation(.spring(response: 0.18, dampingFraction: 0.8), value: model.hovered)
    }

    @ViewBuilder
    private func petal(index: Int, item: FanAction) -> some View {
        let count = model.items.count
        let isHovered = model.hovered == index
        let outer = FanModel.outerRadius + (isHovered ? 12 : 0)
        let shape = PetalShape(index: index, count: count, inner: FanModel.innerRadius, outer: outer)
        ZStack {
            if model.theme == .glass {
                shape.fill(.ultraThinMaterial)
            } else {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            }
            shape.fill(isHovered ? tangerine.opacity(0.9) : Color.clear)
            shape.stroke(Color.white.opacity(0.35), lineWidth: 0.8)
            label(for: item, highlighted: isHovered)
                .offset(labelOffset(index: index, count: count, radius: (FanModel.innerRadius + outer) / 2))
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    @ViewBuilder
    private func label(for item: FanAction, highlighted: Bool) -> some View {
        let color: Color = highlighted ? .white : .primary
        switch item {
        case .convert(let format):
            Text(format.label)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        case .tool(let tool):
            VStack(spacing: 3) {
                Image(systemName: tool.symbol).font(.system(size: 17, weight: .semibold))
                Text(tool.label).font(.system(size: 10, weight: .semibold)).multilineTextAlignment(.center)
            }
            .foregroundStyle(color)
            .frame(width: 74)
        }
    }

    private func labelOffset(index: Int, count: Int, radius: CGFloat) -> CGSize {
        let angle = (-90 + 360.0 / Double(count) * Double(index)) * .pi / 180
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }

    private var hub: some View {
        ZStack {
            Circle().fill(model.theme == .glass ? AnyShapeStyle(.regularMaterial)
                                                : AnyShapeStyle(Color(nsColor: .windowBackgroundColor)))
            Circle().stroke(tangerine.opacity(0.8), lineWidth: 2)
            VStack(spacing: 2) {
                Image(systemName: model.mode == .convert ? "arrow.triangle.2.circlepath" : "wrench.and.screwdriver")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tangerine)
                Text(hubText)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(width: 92)
            }
        }
        .frame(width: FanModel.innerRadius * 2 - 8, height: FanModel.innerRadius * 2 - 8)
    }

    private var hubText: String {
        if let hovered = model.hovered, model.items.indices.contains(hovered) { return model.items[hovered].label }
        return model.subtitle
    }
}

// MARK: - Toast

@MainActor
enum ToastPanel {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, isError: Bool) {
        let host = NSHostingView(rootView:
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? Color.red : Color.orange)
                Text(message).font(.system(size: 13, weight: .medium)).lineLimit(2)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .fixedSize()
        )
        let size = host.fittingSize
        let p = panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        let screen = NSScreen.main?.visibleFrame ?? .zero
        p.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 12, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        panel = p
        hideWork?.cancel()
        let work = DispatchWorkItem { p.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 3.5 : 1.8), execute: work)
    }
}
