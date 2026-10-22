import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

/// Exposure / color / detail .
struct ImageAdjustments {
    var exposure = 0.0, contrast = 1.0, saturation = 1.0, sharpness = 0.0

    private static let context = CIContext()

    func render(_ image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        let output = source
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation])
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: sharpness])
        return Self.context.createCGImage(output, from: source.extent)
    }
}

/// Solid, gradient or picture behind the image, with padding, canvas ratio and rounded corners.
struct BackgroundOptions {
    enum Style: String, CaseIterable, Identifiable {
        case solid = "Solid", gradient = "Gradient", image = "Image"
        var id: String { rawValue }
    }

    var style = Style.gradient
    var color1 = CGColor(red: 1, green: 0.55, blue: 0.12, alpha: 1)
    var color2 = CGColor(red: 0.55, green: 0.2, blue: 0.9, alpha: 1)
    var picture: CGImage?
    var aspect = CropAspect.free
    var padding = 0.08 // of the longer side
    var cornerRadius = 0.04 // of the shorter side

    func render(_ image: CGImage) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pad = padding * max(w, h)
        var canvas = CGSize(width: w + pad * 2, height: h + pad * 2)
        if let ratio = aspect.ratio(original: canvas) {
            if canvas.width / canvas.height < ratio { canvas.width = canvas.height * ratio } else { canvas.height = canvas.width / ratio }
        }
        guard let ctx = CGContext(data: nil, width: Int(canvas.width.rounded()), height: Int(canvas.height.rounded()),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(origin: .zero, size: canvas)
        ctx.setFillColor(color1)
        ctx.fill(full)
        if style == .gradient, let gradient = CGGradient(colorsSpace: nil, colors: [color1, color2] as CFArray, locations: nil) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
        }
        if style == .image, let picture {
            ctx.draw(picture, in: full.aspectFill(CGSize(width: picture.width, height: picture.height)))
        }
        let rect = CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
        let radius = min(cornerRadius * min(w, h), min(w, h) / 2)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}

extension CGRect {
    /// A rect of `size`'s shape that covers this one, centered; callers clip the overflow.
    func aspectFill(_ size: CGSize) -> CGRect {
        let scale = max(width / max(size.width, 1), height / max(size.height, 1))
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }
}

/// One image, live preview, save as a new file. Shared by the Edit and Background editors.
@MainActor
final class ImageToolModel<Options>: ObservableObject {
    let url: URL
    let verb: String
    let suffix: String
    @Published var options: Options { didSet { refresh() } }
    @Published var preview: NSImage?
    @Published var isWorking = false
    @Published var errorMessage: String?
    private let render: (CGImage, Options) -> CGImage?
    private var small: CGImage?

    init(url: URL, verb: String, suffix: String, options: Options, render: @escaping (CGImage, Options) -> CGImage?) {
        self.url = url
        self.verb = verb
        self.suffix = suffix
        self.options = options
        self.render = render
        do {
            small = try ImageConverter.cgImage(url, maxSide: 1200)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refresh() {
        guard let small, let cg = render(small, options) else { return }
        preview = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }

    func save(then close: @escaping () -> Void) {
        isWorking = true
        let url = url, options = options, render = render, suffix = suffix
        EditorWindow.export(verb, file: url, close: close, failed: { self.isWorking = false; self.errorMessage = $0 }) {
            guard let result = render(try ImageConverter.cgImage(url), options) else { throw ConversionError.failed("Could not render image.") }
            let ext = ImageConverter.writableExt(url)
            let out = OutputPlacement.destination(for: url, ext: ext, suffix: suffix)
            try ImageConverter.write(result, to: out, type: ext, quality: Settings.shared.quality)
            return out
        }
    }
}

struct ImageToolView<Options, Controls: View>: View {
    @ObservedObject var model: ImageToolModel<Options>
    let close: () -> Void
    @ViewBuilder let controls: (Binding<Options>) -> Controls

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
            HStack(alignment: .bottom, spacing: 14) {
                controls($model.options)
                Spacer()
                if let message = model.errorMessage, model.preview != nil {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(model.isWorking ? "Saving…" : "Save") { model.save(then: close) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking || model.preview == nil)
            }
            .padding(12)
        }
        .tint(.tangerine)
    }
}

/// Small captioned slider used by the image editors.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    init(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) {
        self.title = title
        _value = value
        self.range = range
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Slider(value: $value, in: range).frame(width: 120)
        }
    }
}

@MainActor
enum ImageEditors {
    static func openEdit(_ url: URL) {
        let model = ImageToolModel(url: url, verb: "Edit", suffix: " edited", options: ImageAdjustments()) { $1.render($0) }
        EditorWindow.present(title: "Edit — \(url.lastPathComponent)", size: CGSize(width: 900, height: 680)) { close in
            ImageToolView(model: model, close: close) { $options in
                LabeledSlider("Exposure", $options.exposure, -2...2)
                LabeledSlider("Contrast", $options.contrast, 0.5...1.5)
                LabeledSlider("Saturation", $options.saturation, 0...2)
                LabeledSlider("Detail", $options.sharpness, 0...2)
                Button("Reset") { options = ImageAdjustments() }
            }
        }
    }

    static func openBackground(_ url: URL) {
        let model = ImageToolModel(url: url, verb: "Background", suffix: " background", options: BackgroundOptions()) { $1.render($0) }
        EditorWindow.present(title: "Background — \(url.lastPathComponent)", size: CGSize(width: 980, height: 680)) { close in
            ImageToolView(model: model, close: close) { $options in
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Style", selection: $options.style) {
                        ForEach(BackgroundOptions.Style.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    HStack {
                        ColorPicker("Color", selection: $options.color1)
                        if options.style == .gradient { ColorPicker("to", selection: $options.color2) }
                        if options.style == .image { Button("Choose…") { options.picture = chooseImage() ?? options.picture } }
                    }
                }
                Picker("Ratio", selection: $options.aspect) {
                    ForEach(CropAspect.allCases.filter { $0 != .original }) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 130)
                LabeledSlider("Spacing", $options.padding, 0...0.3)
                LabeledSlider("Corners", $options.cornerRadius, 0...0.25)
            }
        }
    }

    private static func chooseImage() -> CGImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? ImageConverter.cgImage(url, maxSide: 4000)
    }
}
