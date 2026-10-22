import AppKit
import SwiftUI

/// First-run onboarding: how to open the fan, the tools and file-action modifiers, login item.
@MainActor
final class WelcomeWindowController {
    static let shared = WelcomeWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WelcomeView { [weak self] in
                Settings.shared.hasCompletedWelcome = true
                self?.window?.close()
            })
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class WelcomePager: ObservableObject {
    @Published var page = 0
}

struct WelcomeView: View {
    let onDone: () -> Void
    // A model object instead of @State: the Command Line Tools ship without the SwiftUI macro plugin.
    @ObservedObject private var pager = WelcomePager()
    @ObservedObject private var settings = Settings.shared

    private var page: Int {
        get { pager.page }
        nonmutating set { pager.page = newValue }
    }

    private let tangerine = Color(red: 1.0, green: 0.55, blue: 0.12)

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            Group {
                switch page {
                case 0: intro
                case 1: tools
                default: login
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                if page > 0 { Button("Back") { page -= 1 } }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<3) { Circle().fill($0 == page ? tangerine : Color.secondary.opacity(0.3)).frame(width: 7, height: 7) }
                }
                Spacer()
                Button(page == 2 ? "Get Started" : "Continue") { page == 2 ? onDone() : (page += 1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .tint(tangerine)
        .frame(width: 520, height: 420)
    }

    private var intro: some View {
        VStack(spacing: 14) {
            miniFan(labels: ["PNG", "JPEG", "HEIC", "PDF", "WebP", "TIFF"])
            Text("Convert anything mid-drag").font(.title2.bold())
            Text("Start dragging a file, then hold **\(settings.convertModifier.label)**. A fan of formats opens at your pointer — drop onto one. The result is saved next to the original.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }

    private var tools: some View {
        VStack(spacing: 14) {
            miniFan(labels: ["Compress", "Strip", "Resize", "Rotate", "QR", "Zip"])
            Text("Tools are one key away").font(.title2.bold())
            Text("Hold **\(settings.toolsModifier.label)** while dragging for tools: compress, strip metadata, split or merge PDFs, extract audio, speed up video and more. Hold **\(settings.actionsModifier.label)** for file actions: AirDrop, Float, Copy, Move, Copy Path and Terminal.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }

    private var login: some View {
        VStack(spacing: 14) {
            Image(systemName: "menubar.rectangle").font(.system(size: 54)).foregroundStyle(tangerine)
            Text("Lives in your menu bar").font(.title2.bold())
            Text("Clementine is free with no limits. Change shortcuts, the fan style and output folder in Settings.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                .toggleStyle(.switch)
        }
    }

    private func miniFan(labels: [String]) -> some View {
        ZStack {
            ForEach(labels.indices, id: \.self) { i in
                PetalShape(index: i, count: labels.count, inner: 28, outer: 78)
                    .fill(i == 1 ? tangerine : Color.secondary.opacity(0.15))
                let angle = (-90 + 360.0 / Double(labels.count) * Double(i)) * .pi / 180
                Text(labels[i]).font(.system(size: 9, weight: .bold))
                    .foregroundStyle(i == 1 ? .white : .primary)
                    .offset(x: cos(angle) * 53, y: sin(angle) * 53)
            }
            Circle().stroke(tangerine, lineWidth: 2).frame(width: 50, height: 50)
        }
        .frame(width: 170, height: 170)
    }
}
