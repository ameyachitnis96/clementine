import AppKit
import AVFoundation
import CoreImage
import SwiftUI
import Vision

/// What to hide and how.
struct RedactOptions: Equatable {
    var faces = true
    var text = true
    var solid = false // false = blur
}

enum Redactor {
    /// Face and text boxes, normalized with Vision's bottom-left origin.
    static func regions(in image: CIImage, faces: Bool, text: Bool) throws -> [CGRect] {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        let requests: [VNRequest] = (faces ? [faceRequest] : []) + (text ? [textRequest] : [])
        guard !requests.isEmpty else { return [] }
        try VNImageRequestHandler(ciImage: image).perform(requests)
        return (faceRequest.results ?? []).map(\.boundingBox) + (textRequest.results ?? []).map(\.boundingBox)
    }

    /// Covers the normalized `regions` with a heavy blur or solid black, padded slightly.
    static func apply(_ image: CIImage, regions: [CGRect], solid: Bool) -> CIImage {
        let extent = image.extent
        let cover = solid ? CIImage(color: .black).cropped(to: extent)
            : image.clampedToExtent().applyingGaussianBlur(sigma: max(8, max(extent.width, extent.height) / 40)).cropped(to: extent)
        let pad = max(extent.width, extent.height) * 0.01
        return regions.reduce(image) { result, region in
            let rect = VNImageRectForNormalizedRect(region, Int(extent.width), Int(extent.height))
                .offsetBy(dx: extent.minX, dy: extent.minY).insetBy(dx: -pad, dy: -pad)
            return cover.cropped(to: rect).composited(over: result)
        }
    }

    static func redactImage(_ url: URL, options: RedactOptions) throws -> URL {
        let image = CIImage(cgImage: try ImageConverter.cgImage(url))
        let found = try regions(in: image, faces: options.faces, text: options.text)
        guard let cg = CIContext().createCGImage(apply(image, regions: found, solid: options.solid), from: image.extent) else {
            throw ConversionError.failed("Could not redact image.")
        }
        let ext = ImageConverter.writableExt(url)
        let out = OutputPlacement.destination(for: url, ext: ext, suffix: " redacted")
        try ImageConverter.write(cg, to: out, type: ext, quality: Settings.shared.quality)
        return out
    }

    /// Detects and covers faces/text on every frame. A frame Vision cannot analyze fails the
    /// export instead of slipping through unredacted.
    static func redactVideo(_ url: URL, options: RedactOptions) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let frame = request.sourceImage
            do {
                let found = try regions(in: frame, faces: options.faces, text: options.text)
                request.finish(with: apply(frame, regions: found, solid: options.solid), context: nil)
            } catch {
                request.finish(with: error)
            }
        }
        let target = MediaConverter.editTarget(for: url, hasVideo: true)
        let out = OutputPlacement.destination(for: url, ext: target.ext, suffix: " redacted")
        try await MediaConverter.export(asset, preset: AVAssetExportPresetHighestQuality, to: out, type: target.type) {
            $0.videoComposition = composition
        }
        return out
    }
}

/// Redaction options with a live preview (the first frame for video).
@MainActor
final class RedactModel: ObservableObject {
    let url: URL
    let isVideo: Bool
    @Published var options = RedactOptions() { didSet { render() } }
    @Published var preview: NSImage?
    @Published var found = 0
    @Published var isWorking = false
    @Published var errorMessage: String?
    private var source: CIImage?
    private var faceRegions: [CGRect] = []
    private var textRegions: [CGRect] = []
    private let context = CIContext()

    init(url: URL) {
        self.url = url
        isVideo = FormatCompatibilityMatrix.group(for: url) == .video
        Task { await load() }
    }

    private func load() async {
        do {
            let cg: CGImage
            if isVideo {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                cg = try await generator.image(at: .zero).image
            } else {
                cg = try ImageConverter.cgImage(url)
            }
            let image = CIImage(cgImage: cg)
            // Detect once at full size; the toggles only re-composite.
            let (faces, text) = try await Task.detached {
                (try Redactor.regions(in: image, faces: true, text: false), try Redactor.regions(in: image, faces: false, text: true))
            }.value
            let scale = min(1, 1600 / max(image.extent.width, image.extent.height))
            source = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            faceRegions = faces
            textRegions = text
            render()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func render() {
        guard let source else { return }
        let regions = (options.faces ? faceRegions : []) + (options.text ? textRegions : [])
        found = regions.count
        if let cg = context.createCGImage(Redactor.apply(source, regions: regions, solid: options.solid), from: source.extent) {
            preview = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        }
    }

    func save(then close: @escaping () -> Void) {
        isWorking = true
        let url = url, options = options, isVideo = isVideo
        EditorWindow.export("Redact", file: url, close: close, failed: { self.isWorking = false; self.errorMessage = $0 }) {
            isVideo ? try await Redactor.redactVideo(url, options: options) : try Redactor.redactImage(url, options: options)
        }
    }
}

struct RedactEditorView: View {
    @ObservedObject var model: RedactModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.85)
                if let preview = model.preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit).padding(24)
                } else if let message = model.errorMessage {
                    Text(message).foregroundStyle(.white)
                } else {
                    ProgressView()
                }
            }
            Divider()
            HStack(spacing: 12) {
                Toggle("Faces", isOn: $model.options.faces)
                Toggle("Text", isOn: $model.options.text)
                Picker("Style", selection: $model.options.solid) {
                    Text("Blur").tag(false)
                    Text("Solid").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Text("\(model.found) found" + (model.isVideo ? " in first frame; every frame is scanned" : ""))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let message = model.errorMessage, model.preview != nil {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(model.isWorking ? "Redacting…" : "Redact") { model.save(then: close) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking || model.preview == nil || !(model.options.faces || model.options.text))
            }
            .padding(12)
        }
        .tint(.tangerine)
    }
}

@MainActor
enum RedactEditor {
    static func open(_ url: URL) {
        let model = RedactModel(url: url)
        EditorWindow.present(title: "Redact — \(url.lastPathComponent)", size: CGSize(width: 900, height: 680)) { close in
            RedactEditorView(model: model, close: close)
        }
    }
}
