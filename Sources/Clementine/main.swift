import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = DragGestureMonitor()
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.start()
        menuBar = MenuBarController(monitor: monitor)
        // --preview-fan <convert|tools> <file>: open the fan at screen center without a drag (for screenshots).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--preview-fan"), args.count > i + 2 {
            let screen = NSScreen.main?.frame ?? .zero
            monitor.preview(mode: args[i + 1] == "tools" ? .tools : .convert,
                            urls: [URL(fileURLWithPath: args[i + 2])], at: NSPoint(x: screen.midX, y: screen.midY))
        } else if !Settings.shared.hasCompletedWelcome {
            WelcomeWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) { monitor.stop() }
}

// Command-line mode for scripting and tests: Clementine --convert <ext> <files…> | --tool <name> <files…>
let args = CommandLine.arguments
if args.count >= 4, CLI.modes.contains(args[1]) {
    exit(CLI.run(args))
}

// Snapshot mode for docs: Clementine --render <out-dir> <file> writes PNGs of the fans, welcome and settings.
if args.count == 4, args[1] == "--render" {
    MainActor.assumeIsolated { Snapshots.render(to: URL(fileURLWithPath: args[2]), sample: URL(fileURLWithPath: args[3])) }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
