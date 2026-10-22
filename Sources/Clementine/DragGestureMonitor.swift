import AppKit

/// Watches system-wide file drags. When the user holds a modifier
/// mid-drag, a fan opens at the pointer: convert, tools or file actions. Needs no Accessibility permission: it only
/// observes mouse events and reads the shared drag pasteboard.
@MainActor
final class DragGestureMonitor {
    enum Mode { case convert, tools, actions }

    private var monitors: [Any] = []
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var dragURLs: [URL]?
    private let overlay = ConversionOverlayController()
    var isEnabled = true

    func start() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    func preview(mode: Mode, urls: [URL], at point: NSPoint) {
        overlay.show(mode: mode, urls: urls, at: point)
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            dragURLs = nil
        case .leftMouseDragged:
            guard isEnabled else { return }
            dragged()
        case .flagsChanged:
            // Modifier changes with a stationary pointer produce no drag event.
            guard isEnabled, dragURLs != nil else { return }
            dragged()
        case .leftMouseUp:
            dragURLs = nil
            overlay.dragEnded()
        default:
            break
        }
    }

    private func dragged() {
        let pasteboard = NSPasteboard(name: .drag)
        if dragURLs == nil, pasteboard.changeCount != dragChangeCount {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            dragURLs = urls ?? []
        }
        guard let urls = dragURLs, !urls.isEmpty else { return }

        // Pushing a file drag against the right screen edge opens the shelf under the pointer.
        if Settings.shared.shelfOnScreenEdge, !ShelfController.shared.isVisible {
            let point = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }), point.x >= screen.frame.maxX - 2 {
                ShelfController.shared.show(near: point)
            }
        }

        let settings = Settings.shared
        let flags = NSEvent.modifierFlags.intersection([.shift, .option, .control, .command])
        let mode: Mode?
        if flags == settings.convertModifier.flags { mode = .convert }
        else if flags == settings.toolsModifier.flags { mode = .tools }
        else if flags == settings.actionsModifier.flags { mode = .actions }
        else { mode = nil }

        if let mode {
            overlay.show(mode: mode, urls: urls, at: NSEvent.mouseLocation)
        }
    }
}
