import Foundation

/// Tools shown in the fan when the tools modifier (Command by default) is held.
enum FileTool: String, CaseIterable, Identifiable {
    case crop, trim, addToShelf
    case compress, removeMetadata, resizeHalf, rotate, readQR, redact, createPDF
    case editImage, annotate, addBackground, collage
    case splitPDF, mergePDFs, pdfToImages, organizePDF
    case extractAudio, speedUp, videoSnapshot, mute, splitVideo, join
    case normalizeAudio, toMono, toStereo, visualize, bleep
    case extract
    case copyPath, airDrop, zip, copy, move, terminal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .crop: return "Crop…"
        case .trim: return "Trim…"
        case .addToShelf: return "Float"
        case .compress: return "Compress"
        case .removeMetadata: return "Strip Metadata"
        case .resizeHalf: return "Resize 50%"
        case .rotate: return "Rotate 90°"
        case .readQR: return "Read QR"
        case .redact: return "Redact…"
        case .createPDF: return "Create PDF"
        case .editImage: return "Edit…"
        case .annotate: return "Annotate…"
        case .addBackground: return "Background…"
        case .collage: return "Collage…"
        case .organizePDF: return "Organize…"
        case .splitPDF: return "Split PDF"
        case .mergePDFs: return "Merge PDFs"
        case .pdfToImages: return "Pages → PNG"
        case .extractAudio: return "Extract Audio"
        case .speedUp: return "Speed 2×"
        case .videoSnapshot: return "Snapshot"
        case .mute: return "Mute"
        case .splitVideo: return "Split…"
        case .join: return "Join"
        case .normalizeAudio: return "Normalize"
        case .toMono: return "Mono"
        case .toStereo: return "Stereo"
        case .visualize: return "Visualize"
        case .bleep: return "Bleep…"
        case .extract: return "Extract"
        case .copyPath: return "Copy Path"
        case .airDrop: return "AirDrop"
        case .zip: return "Zip"
        case .copy: return "Copy"
        case .move: return "Move"
        case .terminal: return "Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .crop: return "crop"
        case .trim: return "timeline.selection"
        case .addToShelf: return "tray.and.arrow.down"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .removeMetadata: return "eye.slash"
        case .resizeHalf: return "arrow.up.left.and.down.right.magnifyingglass"
        case .rotate: return "rotate.right"
        case .readQR: return "qrcode.viewfinder"
        case .redact: return "mosaic"
        case .createPDF: return "doc.richtext"
        case .editImage: return "slider.horizontal.3"
        case .annotate: return "pencil.tip.crop.circle"
        case .addBackground: return "photo.artframe"
        case .collage: return "square.grid.2x2"
        case .organizePDF: return "list.number"
        case .splitPDF: return "scissors"
        case .mergePDFs: return "doc.on.doc"
        case .pdfToImages: return "photo.on.rectangle"
        case .extractAudio: return "waveform"
        case .speedUp: return "hare"
        case .videoSnapshot: return "camera"
        case .mute: return "speaker.slash"
        case .splitVideo: return "scissors"
        case .join: return "plus.rectangle.on.rectangle"
        case .normalizeAudio: return "speaker.wave.2"
        case .toMono: return "speaker"
        case .toStereo: return "hifispeaker.2"
        case .visualize: return "waveform.path.ecg"
        case .bleep: return "speaker.badge.exclamationmark"
        case .extract: return "arrow.up.bin"
        case .copyPath: return "link"
        case .airDrop: return "airplayaudio"
        case .zip: return "archivebox"
        case .copy: return "doc.on.doc"
        case .move: return "folder"
        case .terminal: return "terminal"
        }
    }

    /// Tools valid for every file in the drag.
    static func tools(for urls: [URL]) -> [FileTool] {
        let groups = Set(urls.compactMap(FormatCompatibilityMatrix.group(for:)))
        var result: [FileTool] = []
        let single = urls.count == 1
        if single, groups == [.image] || groups == [.video] { result.append(.crop) }
        if single, groups == [.video] || groups == [.audio] { result.append(.trim) }
        if groups == [.image] {
            result += [.compress, .removeMetadata, .resizeHalf, .rotate, .readQR]
            result += single ? [.redact, .editImage, .annotate, .addBackground] : [.createPDF, .collage]
        }
        if groups == [.document] {
            result += urls.count > 1 ? [.mergePDFs] : [.splitPDF, .pdfToImages, .compress, .removeMetadata, .organizePDF]
        }
        if groups == [.video] {
            result += [.compress, .extractAudio, .speedUp, .videoSnapshot, .removeMetadata, .mute]
            result += single ? [.splitVideo, .redact] : [.join]
        }
        if groups == [.audio] {
            result += [.compress, .removeMetadata, .toMono, .toStereo, .visualize]
            if single { result.append(.bleep) }
            if ToolLocator.ffmpeg != nil { result.append(.normalizeAudio) }
        }
        // group(for:) also calls folders .archive; only archive files extract.
        if groups == [.archive], !urls.contains(where: \.hasDirectoryPath) { result.append(.extract) }
        return result
    }

    /// The Control wheel: works on any file or folder.
    static let fileActions: [FileTool] = [.airDrop, .addToShelf, .copy, .move, .copyPath, .terminal]
}
