import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// What the timeline editor produces: one trimmed copy, clips cut at split points, or bleeped ranges.
enum TrimMode {
    case trim, split, bleep

    var verb: String {
        switch self {
        case .trim: return "Trim"
        case .split: return "Split"
        case .bleep: return "Bleep"
        }
    }

    var working: String {
        switch self {
        case .trim: return "Trimming…"
        case .split: return "Splitting…"
        case .bleep: return "Bleeping…"
        }
    }
}

/// Trim state for audio or video.
@MainActor
final class TrimModel: ObservableObject {
    let url: URL
    let mode: TrimMode
    let player: AVPlayer
    @Published var duration: Double = 0
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    @Published var hasVideo = false
    @Published var thumbnails: [NSImage] = []
    @Published var waveform: [Float] = []
    @Published var splits: [Double] = []
    @Published var bleeps: [ClosedRange<Double>] = []
    @Published var isWorking = false
    @Published var errorMessage: String?
    private var timeObserver: Any?
    private var dragStart: Double?

    static let minimumLength = 0.1

    init(url: URL, mode: TrimMode = .trim) {
        self.url = url
        self.mode = mode
        player = AVPlayer(url: url)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        Task { await load() }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    private func load() async {
        let asset = AVURLAsset(url: url)
        do {
            duration = try await asset.load(.duration).seconds
            end = duration
            hasVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
            if hasVideo {
                thumbnails = try await Self.thumbnails(asset, duration: duration)
            } else {
                waveform = try await MediaConverter.waveform(url)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func thumbnails(_ asset: AVAsset, duration: Double, count: Int = 10) async throws -> [NSImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        var images: [NSImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let (cg, _) = try? await generator.image(at: t) {
                images.append(NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height)))
            }
        }
        return images
    }

    private func tick(_ time: Double) {
        guard time.isFinite else { return }
        playhead = time
        if isPlaying, time >= end {
            player.pause()
            isPlaying = false
        }
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        let from = (playhead >= start && playhead < end - 0.05) ? playhead : start
        seek(from)
        player.play()
        isPlaying = true
    }

    func seek(_ seconds: Double) {
        playhead = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Moves a handle by `delta` seconds from where the drag began.
    func dragStartHandle(by delta: Double) {
        let origin = dragStart ?? start
        dragStart = origin
        start = min(max(0, origin + delta), end - Self.minimumLength)
        seek(start)
    }

    func dragEndHandle(by delta: Double) {
        let origin = dragStart ?? end
        dragStart = origin
        end = max(min(duration, origin + delta), start + Self.minimumLength)
        seek(end)
    }

    func endDrag() { dragStart = nil }

    var selectionLabel: String {
        if mode == .split { return "\(Self.format(playhead))  ·  \(splits.count + 1) clips" }
        return "\(Self.format(start)) – \(Self.format(end))  ·  \(String(format: "%.1f", end - start)) s"
    }

    /// Split: a cut at the playhead. Bleep: the selected range.
    func addMark() {
        if mode == .split {
            if playhead > 0, playhead < duration, !splits.contains(where: { abs($0 - playhead) < 0.05 }) { splits.append(playhead) }
        } else {
            bleeps.append(start...end)
        }
    }

    func clearMarks() {
        splits = []
        bleeps = []
    }

    var canSave: Bool {
        guard duration > 0 else { return false }
        switch mode {
        case .trim: return true
        case .split: return !splits.isEmpty
        case .bleep: return !bleeps.isEmpty
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }

    func save(then close: @escaping () -> Void) {
        player.pause()
        isPlaying = false
        isWorking = true
        let url = url, start = start, end = end, mode = mode, splits = splits, bleeps = bleeps
        EditorWindow.export(mode.verb, file: url, close: close, failed: { self.isWorking = false; self.errorMessage = $0 }) {
            switch mode {
            case .trim: return try await MediaConverter.trim(url, start: start, end: end)
            case .split: return try await MediaConverter.split(url, at: splits)
            case .bleep: return try await MediaConverter.bleep(url, ranges: bleeps)
            }
        }
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

struct TrimEditorView: View {
    @ObservedObject var model: TrimModel
    let close: () -> Void

    private let tangerine = Color(red: 1.0, green: 0.55, blue: 0.12)

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Color.black
                if model.hasVideo {
                    PlayerView(player: model.player)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform").font(.system(size: 44)).foregroundStyle(tangerine)
                        Text(model.url.lastPathComponent).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            timeline.frame(height: 64)

            HStack(spacing: 12) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                Text(model.selectionLabel).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if let message = model.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                if model.mode != .trim {
                    Button(model.mode == .split ? "Add Split" : "Add Range") { model.addMark() }
                    Button("Clear") { model.clearMarks() }.disabled(model.splits.isEmpty && model.bleeps.isEmpty)
                }
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(model.isWorking ? model.mode.working : model.mode.verb) { model.save(then: close) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking || !model.canSave)
            }
        }
        .padding(16)
        .tint(tangerine)
    }

    private var timeline: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let total = max(model.duration, 0.001)
            let x = { (t: Double) in CGFloat(t / total) * width }
            ZStack(alignment: .topLeading) {
                track(width: width, height: geo.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        model.seek(min(max(0, Double(value.location.x / width) * total), total))
                    })

                ForEach(Array(model.bleeps.enumerated()), id: \.offset) { _, r in
                    Rectangle().fill(Color.red.opacity(0.45))
                        .frame(width: max(2, x(r.upperBound) - x(r.lowerBound)), height: geo.size.height)
                        .offset(x: x(r.lowerBound)).allowsHitTesting(false)
                }
                ForEach(model.splits, id: \.self) { t in
                    Rectangle().fill(tangerine).frame(width: 3, height: geo.size.height + 8)
                        .offset(x: x(t) - 1.5, y: -4).allowsHitTesting(false)
                }

                if model.mode != .split { selection(width: width, height: geo.size.height, x: x, total: total) }

                Rectangle().fill(Color.white).frame(width: 2, height: geo.size.height + 8)
                    .offset(x: x(model.playhead) - 1, y: -4).allowsHitTesting(false)
            }
        }
    }

    /// Dimmed outside, outlined inside, with draggable start/end handles.
    @ViewBuilder
    private func selection(width: CGFloat, height: CGFloat, x: @escaping (Double) -> CGFloat, total: Double) -> some View {
        Rectangle().fill(Color.black.opacity(0.5)).frame(width: x(model.start), height: height).allowsHitTesting(false)
        Rectangle().fill(Color.black.opacity(0.5)).frame(width: max(0, width - x(model.end)), height: height)
            .offset(x: x(model.end)).allowsHitTesting(false)
        RoundedRectangle(cornerRadius: 6).stroke(tangerine, lineWidth: 3)
            .frame(width: max(0, x(model.end) - x(model.start)), height: height)
            .offset(x: x(model.start)).allowsHitTesting(false)
        handle(height: height)
            .offset(x: x(model.start) - 7)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { model.dragStartHandle(by: Double($0.translation.width / width) * total) }
                .onEnded { _ in model.endDrag() })
        handle(height: height)
            .offset(x: x(model.end) - 7)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { model.dragEndHandle(by: Double($0.translation.width / width) * total) }
                .onEnded { _ in model.endDrag() })
    }

    private func handle(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(tangerine)
            .overlay(Capsule().fill(Color.white).frame(width: 3, height: 18))
            .frame(width: 14, height: height + 6)
            .offset(y: -3)
    }

    @ViewBuilder
    private func track(width: CGFloat, height: CGFloat) -> some View {
        if model.hasVideo {
            HStack(spacing: 0) {
                ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(max(model.thumbnails.count, 1)), height: height).clipped()
                }
            }
            .frame(width: width, height: height)
            .background(Color.gray.opacity(0.3))
        } else {
            Canvas { context, size in
                let bars = model.waveform
                guard !bars.isEmpty else { return }
                let step = size.width / CGFloat(bars.count)
                for (i, v) in bars.enumerated() {
                    let h = max(1.5, CGFloat(v) * size.height * 0.9)
                    let rect = CGRect(x: CGFloat(i) * step + step * 0.15, y: (size.height - h) / 2, width: step * 0.7, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(tangerine.opacity(0.85)))
                }
            }
            .frame(width: width, height: height)
            .background(Color.gray.opacity(0.18))
        }
    }
}

@MainActor
enum TrimEditor {
    static func open(_ url: URL, mode: TrimMode = .trim) {
        let model = TrimModel(url: url, mode: mode)
        EditorWindow.present(title: "\(mode.verb) — \(url.lastPathComponent)", size: CGSize(width: 820, height: 600)) { close in
            TrimEditorView(model: model, close: {
                model.player.pause()
                close()
            })
        }
    }
}
