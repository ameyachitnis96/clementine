import AppKit
import ServiceManagement

/// Modifier combos that open the fan while dragging.
enum DragModifierCombination: String, CaseIterable, Identifiable {
    case shift, option, control, shiftControl, command
    var id: String { rawValue }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: return [.shift]
        case .option: return [.option]
        case .control: return [.control]
        case .shiftControl: return [.shift, .control]
        case .command: return [.command]
        }
    }

    var label: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .shiftControl: return "⇧⌃ Shift+Control"
        case .command: return "⌘ Command"
        }
    }
}

enum FanTheme: String, CaseIterable, Identifiable {
    case glass, solid
    var id: String { rawValue }
}

/// User preferences, persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var convertModifier: DragModifierCombination {
        didSet { defaults.set(convertModifier.rawValue, forKey: "convertModifier") }
    }
    @Published var toolsModifier: DragModifierCombination {
        didSet { defaults.set(toolsModifier.rawValue, forKey: "toolsModifier") }
    }
    @Published var actionsModifier: DragModifierCombination {
        didSet { defaults.set(actionsModifier.rawValue, forKey: "actionsModifier") }
    }
    @Published var theme: FanTheme { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    @Published var revealInFinder: Bool { didSet { defaults.set(revealInFinder, forKey: "revealInFinder") } }
    @Published var quality: Double { didSet { defaults.set(quality, forKey: "quality") } }
    @Published var outputFolderPath: String? { didSet { defaults.set(outputFolderPath, forKey: "outputFolder") } }
    @Published var shelfOnScreenEdge: Bool { didSet { defaults.set(shelfOnScreenEdge, forKey: "shelfOnScreenEdge") } }
    @Published var hasCompletedWelcome: Bool { didSet { defaults.set(hasCompletedWelcome, forKey: "welcomeDone") } }

    var outputFolder: URL? { outputFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    private init() {
        convertModifier = DragModifierCombination(rawValue: defaults.string(forKey: "convertModifier") ?? "") ?? .shift
        toolsModifier = DragModifierCombination(rawValue: defaults.string(forKey: "toolsModifier") ?? "") ?? .command
        actionsModifier = DragModifierCombination(rawValue: defaults.string(forKey: "actionsModifier") ?? "") ?? .control
        theme = FanTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .glass
        playSound = defaults.object(forKey: "playSound") as? Bool ?? true
        revealInFinder = defaults.object(forKey: "revealInFinder") as? Bool ?? false
        quality = defaults.object(forKey: "quality") as? Double ?? 0.85
        outputFolderPath = defaults.string(forKey: "outputFolder")
        shelfOnScreenEdge = defaults.object(forKey: "shelfOnScreenEdge") as? Bool ?? true
        hasCompletedWelcome = defaults.bool(forKey: "welcomeDone")
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Clementine: login item change failed: \(error.localizedDescription)")
            }
        }
    }
}
