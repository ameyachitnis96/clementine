import AppKit
import SwiftUI

/// Renders the app's real views offscreen so docs and reviews can see them without a drag.
@MainActor
enum Snapshots {
    static func render(to folder: URL, sample: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, mode) in [("fan-convert", DragGestureMonitor.Mode.convert), ("fan-tools", .tools)] {
            let model = FanModel()
            model.theme = .solid
            model.mode = mode
            model.items = mode == .convert
                ? FormatCompatibilityMatrix.outputs(for: sample).map(FanAction.convert)
                : FileTool.tools(for: [sample]).map(FanAction.tool)
            model.hovered = 1
            model.subtitle = sample.lastPathComponent
            write(FanView(model: model).background(Color(white: 0.92)), size: CGSize(width: FanModel.size, height: FanModel.size),
                  to: folder.appendingPathComponent("\(name).png"))
        }
        write(WelcomeView {}.background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 520, height: 420),
              to: folder.appendingPathComponent("welcome.png"))
        write(SettingsView(settings: .shared).background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 460, height: 620),
              to: folder.appendingPathComponent("settings.png"))

        // Editors need their async loads (frames, thumbnails, waveform) to land first.
        let fixtures = sample.deletingLastPathComponent()
        let crop = CropModel(url: sample)
        spin { crop.preview != nil || crop.errorMessage != nil }
        crop.aspect = .fourThree
        write(CropEditorView(model: crop, close: {}).background(Color(nsColor: .windowBackgroundColor)),
              size: CGSize(width: 900, height: 600), to: folder.appendingPathComponent("crop.png"))

        for name in ["clip.mov", "voice.aiff"] {
            let url = fixtures.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let trim = TrimModel(url: url)
            spin { trim.duration > 0 && (!trim.thumbnails.isEmpty || !trim.waveform.isEmpty) }
            trim.start = trim.duration * 0.2
            trim.end = trim.duration * 0.7
            trim.playhead = trim.duration * 0.45
            write(TrimEditorView(model: trim, close: {}).background(Color(nsColor: .windowBackgroundColor)),
                  size: CGSize(width: 820, height: 520),
                  to: folder.appendingPathComponent("trim-\(url.deletingPathExtension().lastPathComponent).png"))
        }

        let shelf = ShelfModel()
        let shelved = (try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? []
        shelf.add(Array(shelved.filter { !$0.hasDirectoryPath }.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(6)))
        spin(timeout: 2) { false }
        write(ShelfView(model: shelf, close: {}).padding(20).background(Color(white: 0.85)),
              size: CGSize(width: ShelfController.size.width + 40, height: ShelfController.size.height + 40),
              to: folder.appendingPathComponent("shelf.png"))
        write(ShelfView(model: ShelfModel(), close: {}).padding(20).background(Color(white: 0.85)),
              size: CGSize(width: ShelfController.size.width + 40, height: ShelfController.size.height + 40),
              to: folder.appendingPathComponent("shelf-empty.png"))
    }

    private static func spin(timeout: TimeInterval = 8, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private static func write<V: View>(_ view: V, size: CGSize, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
    }
}
