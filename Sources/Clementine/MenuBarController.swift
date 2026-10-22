import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor: DragGestureMonitor
    private var settingsWindow: NSWindow?

    init(monitor: DragGestureMonitor) {
        self.monitor = monitor
        super.init()
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "circle.hexagongrid.circle", accessibilityDescription: "Clementine")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared
        let hint = NSMenuItem(title: "Drag a file + hold \(s.convertModifier.label) to convert", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        let toolsHint = NSMenuItem(title: "\(s.toolsModifier.label) for tools, \(s.actionsModifier.label) for file actions", action: nil, keyEquivalent: "")
        toolsHint.isEnabled = false
        menu.addItem(toolsHint)
        menu.addItem(.separator())

        menu.addItem(item("Convert Files…", #selector(convertFiles), "o"))
        menu.addItem(item("Tools for Files…", #selector(toolFiles), "t"))
        let shelfCount = ShelfController.shared.model.items.count
        menu.addItem(item((ShelfController.shared.isVisible ? "Hide Shelf" : "Show Shelf") + (shelfCount > 0 ? " (\(shelfCount))" : ""),
                          #selector(toggleShelf), "s"))
        let toggle = item(monitor.isEnabled ? "Pause Drag Gesture" : "Resume Drag Gesture", #selector(toggleMonitor), "")
        menu.addItem(toggle)

        let records = TaskStore.shared.records
        if !records.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for record in records.prefix(6) {
                let prefix: String
                switch record.status {
                case .running: prefix = "⏳ "
                case .done: prefix = "✓ "
                case .failed: prefix = "⚠︎ "
                }
                let entry = item(prefix + record.title, #selector(revealRecord(_:)), "")
                entry.representedObject = record.output
                if case .failed(let message) = record.status { entry.toolTip = message }
                entry.isEnabled = record.output != nil
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        let free = NSMenuItem(title: "Free & unlimited · \(TaskStore.shared.completedCount) actions done", action: nil, keyEquivalent: "")
        free.isEnabled = false
        menu.addItem(free)
        menu.addItem(item("Settings…", #selector(openSettings), ","))
        menu.addItem(item("Show Welcome", #selector(showWelcome), ""))
        menu.addItem(item("Quit Clementine", #selector(quit), "q"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: Actions

    @objc private func convertFiles() { pickFiles(tools: false) }
    @objc private func toolFiles() { pickFiles(tools: true) }

    /// Fallback to the drag gesture: choose files, then pick from a pop-up menu.
    private func pickFiles(tools: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        let actions: [FanAction] = tools
            ? FileTool.tools(for: urls).map(FanAction.tool)
            : FormatCompatibilityMatrix.outputs(for: urls[0]).map(FanAction.convert)
        let menu = NSMenu()
        for action in actions {
            let entry = NSMenuItem(title: action.label, action: #selector(runPicked(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = PickedAction(action: action, urls: urls)
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func runPicked(_ sender: NSMenuItem) {
        guard let picked = sender.representedObject as? PickedAction else { return }
        ActionRunner.run(picked.action, on: picked.urls)
    }

    @objc private func toggleMonitor() { monitor.isEnabled.toggle() }
    @objc private func toggleShelf() { ShelfController.shared.toggle() }

    @objc private func revealRecord(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Clementine Settings"
            window.contentView = NSHostingView(rootView: SettingsView(settings: .shared))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showWelcome() { WelcomeWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}

final class PickedAction: NSObject {
    let action: FanAction
    let urls: [URL]
    init(action: FanAction, urls: [URL]) { self.action = action; self.urls = urls }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section("Gesture") {
                Picker("Convert while dragging with", selection: $settings.convertModifier) {
                    ForEach(DragModifierCombination.allCases) { Text($0.label).tag($0) }
                }
                Picker("Tools while dragging with", selection: $settings.toolsModifier) {
                    ForEach(DragModifierCombination.allCases) { Text($0.label).tag($0) }
                }
                Picker("File actions while dragging with", selection: $settings.actionsModifier) {
                    ForEach(DragModifierCombination.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Appearance") {
                Picker("Fan style", selection: $settings.theme) {
                    Text("Liquid Glass").tag(FanTheme.glass)
                    Text("Solid").tag(FanTheme.solid)
                }
                .pickerStyle(.segmented)
                Toggle("Play sounds", isOn: $settings.playSound)
            }
            Section("Output") {
                Slider(value: $settings.quality, in: 0.3...1) { Text("Lossy quality \(Int(settings.quality * 100))%") }
                HStack {
                    Text("Save to")
                    Spacer()
                    Text(settings.outputFolderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Next to original")
                        .foregroundStyle(.secondary)
                    Button("Choose…") { chooseFolder() }
                    if settings.outputFolderPath != nil { Button("Reset") { settings.outputFolderPath = nil } }
                }
                Toggle("Reveal results in Finder", isOn: $settings.revealInFinder)
            }
            Section("Shelf") {
                Toggle("Open shelf when dragging files to the right screen edge", isOn: $settings.shelfOnScreenEdge)
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                LabeledContent("Plan", value: "Free — unlimited actions, all tools")
                LabeledContent("ffmpeg", value: ToolLocator.ffmpeg ?? "not found (MP3/FLAC/MKV disabled)")
                LabeledContent("cwebp", value: ToolLocator.cwebp ?? "not found (WebP disabled)")
            }
        }
        .formStyle(.grouped)
        .tint(Color(red: 1.0, green: 0.55, blue: 0.12))
        .frame(width: 460)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK { settings.outputFolderPath = panel.url?.path }
    }
}
