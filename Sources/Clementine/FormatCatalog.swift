import Foundation
import UniformTypeIdentifiers

/// Broad family a file belongs to. Drives which petals the fan shows.
enum FormatGroup: String, CaseIterable, Codable {
    case image, audio, video, document, subtitle, archive, text
}

/// An output format the conversion fan can offer.
struct ConversionFormat: Hashable, Identifiable {
    let ext: String
    let label: String
    let group: FormatGroup
    var id: String { ext }

    static let jpeg = ConversionFormat(ext: "jpg", label: "JPEG", group: .image)
    static let png = ConversionFormat(ext: "png", label: "PNG", group: .image)
    static let heic = ConversionFormat(ext: "heic", label: "HEIC", group: .image)
    static let webp = ConversionFormat(ext: "webp", label: "WebP", group: .image)
    static let tiff = ConversionFormat(ext: "tiff", label: "TIFF", group: .image)
    static let bmp = ConversionFormat(ext: "bmp", label: "BMP", group: .image)
    static let gif = ConversionFormat(ext: "gif", label: "GIF", group: .image)
    static let pdf = ConversionFormat(ext: "pdf", label: "PDF", group: .document)
    static let txt = ConversionFormat(ext: "txt", label: "Text", group: .text)
    static let html = ConversionFormat(ext: "html", label: "HTML", group: .text)
    static let rtf = ConversionFormat(ext: "rtf", label: "RTF", group: .text)
    static let docx = ConversionFormat(ext: "docx", label: "Word", group: .document)

    static let mp3 = ConversionFormat(ext: "mp3", label: "MP3", group: .audio)
    static let m4a = ConversionFormat(ext: "m4a", label: "M4A", group: .audio)
    static let wav = ConversionFormat(ext: "wav", label: "WAV", group: .audio)
    static let aiff = ConversionFormat(ext: "aiff", label: "AIFF", group: .audio)
    static let flac = ConversionFormat(ext: "flac", label: "FLAC", group: .audio)
    static let caf = ConversionFormat(ext: "caf", label: "CAF", group: .audio)

    static let mp4 = ConversionFormat(ext: "mp4", label: "MP4", group: .video)
    static let mov = ConversionFormat(ext: "mov", label: "MOV", group: .video)
    static let m4v = ConversionFormat(ext: "m4v", label: "M4V", group: .video)

    static let srt = ConversionFormat(ext: "srt", label: "SRT", group: .subtitle)
    static let vtt = ConversionFormat(ext: "vtt", label: "VTT", group: .subtitle)

    static let zip = ConversionFormat(ext: "zip", label: "ZIP", group: .archive)
    static let tgz = ConversionFormat(ext: "tar.gz", label: "TAR.GZ", group: .archive)
    static let folder = ConversionFormat(ext: "", label: "Extract", group: .archive)
}

/// Input group -> offered outputs.
enum FormatCompatibilityMatrix {
    static func group(for url: URL) -> FormatGroup? {
        if url.hasDirectoryPath { return .archive }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "srt": return .subtitle
        case "vtt": return .subtitle
        case "zip", "tar", "gz", "tgz", "rar": return .archive
        case "txt", "md", "markdown", "html", "htm", "rtf", "docx", "doc", "odt", "json", "csv":
            return .text
        case "pdf": return .document
        default: break
        }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .text) { return .text }
        return nil
    }

    static func outputs(for url: URL) -> [ConversionFormat] {
        let ext = url.pathExtension.lowercased()
        let raw: [ConversionFormat]
        switch group(for: url) {
        case .image:
            raw = [.jpeg, .png, .heic, .webp, .tiff, .bmp, .gif, .pdf]
        case .audio:
            raw = [.mp3, .m4a, .wav, .aiff, .flac, .caf]
        case .video:
            raw = [.mp4, .mov, .m4v, .gif, .m4a, .wav, .jpeg]
        case .document:
            raw = [.png, .jpeg, .txt, .html, .rtf, .tiff]
        case .text:
            raw = [.pdf, .txt, .html, .rtf, .docx, .png]
        case .subtitle:
            raw = [.srt, .vtt, .txt]
        case .archive:
            raw = url.hasDirectoryPath ? [.zip, .tgz] : [.folder]
        case nil:
            raw = [.zip]
        }
        return raw.filter { $0.ext != ext && !(ext == "jpeg" && $0.ext == "jpg") }
            .filter { $0 != .webp || ToolLocator.cwebp != nil }
            .filter { ($0 != .mp3 && $0 != .flac) || ToolLocator.ffmpeg != nil }
    }
}

/// Locates optional helper binaries. Uses ffmpeg/cwebp when they are
/// installed and hides formats that need them otherwise.
enum ToolLocator {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static func find(_ name: String) -> String? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Tools"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        return searchPaths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let ffmpeg = find("ffmpeg")
    static let cwebp = find("cwebp")
    static let dwebp = find("dwebp")
}
