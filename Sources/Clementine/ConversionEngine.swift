import AppKit
import AVFoundation
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ConversionError: LocalizedError {
    case unreadable(URL)
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): return "Could not read \(url.lastPathComponent)."
        case .unsupported(let what): return "\(what) is not supported."
        case .failed(let why): return why
        }
    }
}

/// Where converted files land. Writes a new copy beside the original.
enum OutputPlacement {
    static func destination(for source: URL, ext: String, suffix: String = "") -> URL {
        let folder = Settings.shared.outputFolder ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + suffix
        return uniqueURL(in: folder, base: base, ext: ext)
    }

    static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        func make(_ name: String) -> URL {
            ext.isEmpty ? folder.appendingPathComponent(name, isDirectory: true)
                        : folder.appendingPathComponent(name).appendingPathExtension(ext)
        }
        var candidate = make(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(base) \(n)")
            n += 1
        }
        return candidate
    }
}

/// Performs every conversion offered by the fan. All work is local and offline.
enum ConversionEngine {
    static func convert(_ source: URL, to format: ConversionFormat) async throws -> URL {
        let group = FormatCompatibilityMatrix.group(for: source)
        switch (group, format.group) {
        case (.image, .image), (.image, .document):
            return try ImageConverter.convert(source, to: format)
        case (.audio, _):
            return try await MediaConverter.convertAudio(source, to: format)
        case (.video, .video):
            return try await MediaConverter.convertVideo(source, to: format)
        case (.video, .audio):
            return try await MediaConverter.convertAudio(source, to: format)
        case (.video, .image):
            return format == .gif ? try await MediaConverter.gif(from: source)
                                  : try await MediaConverter.snapshot(source, ext: format.ext)
        case (.document, _):
            return try DocumentConverter.fromPDF(source, to: format)
        case (.text, _):
            return try DocumentConverter.fromText(source, to: format)
        case (.subtitle, _):
            return try SubtitleConverter.convert(source, to: format)
        case (.archive, _), (nil, .archive):
            return try ArchiveConverter.convert([source], to: format)
        default:
            throw ConversionError.unsupported("\(source.pathExtension.uppercased()) → \(format.label)")
        }
    }
}

// MARK: - Images

enum ImageConverter {
    static func utType(for ext: String) -> UTType? {
        switch ext {
        case "jpg": return .jpeg
        case "png": return .png
        case "heic": return .heic
        case "tiff": return .tiff
        case "bmp": return .bmp
        case "gif": return .gif
        default: return UTType(filenameExtension: ext)
        }
    }

    static func source(_ url: URL) throws -> CGImageSource {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw ConversionError.unreadable(url)
        }
        return src
    }

    static func cgImage(_ url: URL, maxSide: Int = 100_000) throws -> CGImage {
        let src = try source(url)
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxSide]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ConversionError.unreadable(url)
        }
        return image
    }

    static func convert(_ url: URL, to format: ConversionFormat) throws -> URL {
        let out = OutputPlacement.destination(for: url, ext: format.ext)
        switch format {
        case .pdf:
            let image = NSImage(cgImage: try cgImage(url), size: .zero)
            guard let page = PDFPage(image: image) else { throw ConversionError.failed("Could not build PDF page.") }
            let doc = PDFDocument()
            doc.insert(page, at: 0)
            guard doc.write(to: out) else { throw ConversionError.failed("Could not write PDF.") }
        case .webp:
            try webp(from: url, to: out, quality: 85)
        default:
            try write(try cgImage(url), to: out, type: format.ext, quality: Settings.shared.quality)
        }
        return out
    }

    static func write(_ image: CGImage, to out: URL, type ext: String, quality: Double,
                      properties: [CFString: Any] = [:]) throws {
        guard let type = utType(for: ext),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionError.unsupported(ext.uppercased())
        }
        var props = properties
        props[kCGImageDestinationLossyCompressionQuality] = quality
        var img = image
        if ext == "jpg" || ext == "bmp", image.alphaInfo != .none, let flat = flatten(image) { img = flat }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.failed("Could not encode \(ext.uppercased()).") }
    }

    /// JPEG has no alpha: composite onto white like Preview does.
    static func flatten(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    static func webp(from url: URL, to out: URL, quality: Int) throws {
        guard let cwebp = ToolLocator.cwebp else { throw ConversionError.unsupported("WebP (install cwebp)") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(try cgImage(url), to: tmp, type: "png", quality: 1)
        try Shell.run(cwebp, ["-quiet", "-q", "\(quality)", tmp.path, "-o", out.path])
    }

    // MARK: Tools

    static func compress(_ url: URL) throws -> URL {
        let ext = url.pathExtension.lowercased()
        let keep = ["jpg", "jpeg", "heic", "webp"].contains(ext)
        let outExt = keep ? (ext == "jpeg" ? "jpg" : ext) : "jpg"
        let out = OutputPlacement.destination(for: url, ext: outExt, suffix: " compressed")
        if outExt == "webp" { try webp(from: url, to: out, quality: 60); return out }
        try write(try cgImage(url), to: out, type: outExt, quality: 0.6)
        return out
    }

    static func resize(_ url: URL, factor: Double) throws -> URL {
        let src = try source(url)
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maxSide = max(1, Int(Double(max(w, h)) * factor))
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxSide]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ConversionError.unreadable(url)
        }
        let ext = writableExt(url)
        let out = OutputPlacement.destination(for: url, ext: ext, suffix: " \(Int(factor * 100))%")
        try write(image, to: out, type: ext, quality: Settings.shared.quality)
        return out
    }

    static func rotate(_ url: URL) throws -> URL {
        let image = try cgImage(url)
        guard let ctx = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.failed("Could not rotate image.")
        }
        ctx.translateBy(x: CGFloat(image.height), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rotated = ctx.makeImage() else { throw ConversionError.failed("Could not rotate image.") }
        let ext = writableExt(url)
        let out = OutputPlacement.destination(for: url, ext: ext, suffix: " rotated")
        try write(rotated, to: out, type: ext, quality: Settings.shared.quality)
        return out
    }

    /// Writes a copy without EXIF/GPS/IPTC/XMP. Copies the encoded image losslessly
    /// (no re-encode) and keeps only the orientation tag.
    static func stripMetadata(_ url: URL) throws -> URL {
        let src = try source(url)
        guard let srcType = CGImageSourceGetType(src) else { throw ConversionError.unreadable(url) }
        let out = OutputPlacement.destination(for: url, ext: url.pathExtension.lowercased(), suffix: " clean")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, srcType, 1, nil) else {
            throw ConversionError.unsupported(url.pathExtension.uppercased())
        }
        let metadata = CGImageMetadataCreateMutable()
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        if let orientation = props?[kCGImagePropertyOrientation] as? Int {
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                         kCGImagePropertyTIFFOrientation, orientation as CFNumber)
        }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata,
                                        kCGImageDestinationMergeMetadata: false,
                                        kCGImageMetadataShouldExcludeXMP: true,
                                        kCGImageMetadataShouldExcludeGPS: true]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &error) else {
            throw ConversionError.failed(error?.takeRetainedValue().localizedDescription ?? "Could not write clean copy.")
        }
        return out
    }

    static func writableExt(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "jpeg" { return "jpg" }
        return ["jpg", "png", "heic", "tiff", "bmp", "gif"].contains(ext) ? ext : "png"
    }
}

// MARK: - Audio / video

enum MediaConverter {
    static func export(_ asset: AVAsset, preset: String, to out: URL, type: AVFileType,
                       configure: ((AVAssetExportSession) -> Void)? = nil) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.unsupported("Export preset \(preset)")
        }
        session.outputURL = out
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        configure?(session)
        await session.export()
        if session.status != .completed {
            throw ConversionError.failed(session.error?.localizedDescription ?? "Export failed.")
        }
    }

    static func convertVideo(_ url: URL, to format: ConversionFormat) async throws -> URL {
        let out = OutputPlacement.destination(for: url, ext: format.ext)
        let asset = AVURLAsset(url: url)
        let type: AVFileType = format == .mov ? .mov : (format == .m4v ? .m4v : .mp4)
        do {
            try await export(asset, preset: AVAssetExportPresetHighestQuality, to: out, type: type)
        } catch where ToolLocator.ffmpeg != nil {
            // AVFoundation cannot read MKV/WebM/AVI; fall back to ffmpeg when present.
            try Shell.run(ToolLocator.ffmpeg!, ["-v", "error", "-y", "-i", url.path, "-c:v", "libx264", "-c:a", "aac", out.path])
        }
        return out
    }

    static func convertAudio(_ url: URL, to format: ConversionFormat) async throws -> URL {
        if try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).isEmpty {
            throw ConversionError.failed("\(url.lastPathComponent) has no audio track.")
        }
        let out = OutputPlacement.destination(for: url, ext: format.ext)
        switch format {
        case .m4a:
            try await export(AVURLAsset(url: url), preset: AVAssetExportPresetAppleM4A, to: out, type: .m4a)
        case .wav, .aiff, .caf:
            try await pcm(from: url, to: out, format: format)
        default:
            guard let ffmpeg = ToolLocator.ffmpeg else { throw ConversionError.unsupported("\(format.label) (install ffmpeg)") }
            try Shell.run(ffmpeg, ["-v", "error", "-y", "-i", url.path, "-vn", out.path])
        }
        return out
    }

    /// Decodes any AVFoundation-readable track (audio file or movie) to linear PCM.
    static func pcm(from url: URL, to out: URL, format: ConversionFormat) async throws {
        try await transcodeAudio(url, to: out, fileType: format == .wav ? .wav : (format == .aiff ? .aiff : .caf))
    }

    /// Re-encodes the first audio track to 16-bit PCM, or to AAC when `bitRate` is set.
    /// `channels` down- or up-mixes; by default the source layout is kept (at most stereo).
    static func transcodeAudio(_ url: URL, to out: URL, fileType: AVFileType, channels: Int? = nil, bitRate: Int? = nil) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.failed("No audio track found.")
        }
        let desc = try await track.load(.formatDescriptions).first
        let asbd = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let channelCount = channels ?? min(Int(asbd?.mChannelsPerFrame ?? 2), 2)
        var rate = asbd?.mSampleRate ?? 44_100
        // The AAC encoder rejects these bitrates at low rates (e.g. 22 kHz) and anything above 48 kHz.
        if bitRate != nil { rate = rate >= 48_000 ? 48_000 : 44_100 }
        let reader = try AVAssetReader(asset: asset)
        let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                                  AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
                                  AVLinearPCMIsBigEndianKey: fileType == .aiff,
                                  AVSampleRateKey: rate, AVNumberOfChannelsKey: channelCount]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: out, fileType: fileType)
        let settings: [String: Any] = bitRate.map {
            [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channelCount, AVEncoderBitRateKey: $0]
        } ?? pcm
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writer.add(input)
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        while let buffer = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            input.append(buffer)
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw ConversionError.failed(writer.error?.localizedDescription ?? "Audio export failed.") }
    }

    static func snapshot(_ url: URL, ext: String = "png") async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTimeMultiplyByFloat64(duration, multiplier: 0.5)
        let (image, _) = try await generator.image(at: time)
        let out = OutputPlacement.destination(for: url, ext: ext, suffix: " snapshot")
        try ImageConverter.write(image, to: out, type: ext, quality: 0.9)
        return out
    }

    /// Animated GIF of the first 10 seconds at 10 fps, 480 px wide.
    static func gif(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = min(try await asset.load(.duration).seconds, 10)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let fps = 10.0
        let count = max(1, Int(duration * fps))
        let out = OutputPlacement.destination(for: url, ext: "gif")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ConversionError.failed("Could not create GIF.")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            let (frame, _) = try await generator.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600))
            CGImageDestinationAddImage(dest, frame, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.failed("Could not write GIF.") }
        return out
    }

    static func compressVideo(_ url: URL) async throws -> URL {
        let out = OutputPlacement.destination(for: url, ext: "mp4", suffix: " compressed")
        try await export(AVURLAsset(url: url), preset: AVAssetExportPresetHEVC1920x1080, to: out, type: .mp4)
        return out
    }

    static func extractAudio(_ url: URL) async throws -> URL {
        try await convertAudio(url, to: .m4a)
    }

    static func speed(_ url: URL, factor: Double) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        try await composition.insertTimeRange(range, of: asset, at: .zero)
        if let track = try await asset.loadTracks(withMediaType: .video).first,
           let compTrack = composition.tracks(withMediaType: .video).first {
            compTrack.preferredTransform = try await track.load(.preferredTransform)
        }
        composition.scaleTimeRange(range, toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 1 / factor))
        let out = OutputPlacement.destination(for: url, ext: "mp4", suffix: " \(Int(factor))x")
        try await export(composition, preset: AVAssetExportPresetHighestQuality, to: out, type: .mp4) { session in
            session.audioTimePitchAlgorithm = .spectral
        }
        return out
    }

    static func normalize(_ url: URL) throws -> URL {
        guard let ffmpeg = ToolLocator.ffmpeg else { throw ConversionError.unsupported("Normalize (install ffmpeg)") }
        let out = OutputPlacement.destination(for: url, ext: url.pathExtension, suffix: " normalized")
        try Shell.run(ffmpeg, ["-v", "error", "-y", "-i", url.path, "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", out.path])
        return out
    }

    static func stripMetadata(_ url: URL) async throws -> URL {
        if let ffmpeg = ToolLocator.ffmpeg {
            let out = OutputPlacement.destination(for: url, ext: url.pathExtension, suffix: " clean")
            try Shell.run(ffmpeg, ["-v", "error", "-y", "-i", url.path, "-map", "0", "-map_metadata", "-1",
                                   "-map_chapters", "-1", "-c", "copy", out.path])
            return out
        }
        // Without ffmpeg: AVFoundation copy that writes no metadata (MP4/MOV/M4A out).
        let asset = AVURLAsset(url: url)
        let hasVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
        let target = editTarget(for: url, hasVideo: hasVideo)
        let out = OutputPlacement.destination(for: url, ext: target.ext, suffix: " clean")
        try await exportEdit(asset, to: out, type: target.type, hasVideo: hasVideo) {
            $0.metadata = []
            $0.metadataItemFilter = .forSharing()
        }
        return out
    }
}

// MARK: - Documents

enum DocumentConverter {
    static func fromPDF(_ url: URL, to format: ConversionFormat) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url) }
        switch format {
        case .txt:
            let out = OutputPlacement.destination(for: url, ext: "txt")
            try (doc.string ?? "").write(to: out, atomically: true, encoding: .utf8)
            return out
        case .html, .rtf:
            let text = NSMutableAttributedString()
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.attributedString { text.append(page); text.append(NSAttributedString(string: "\n")) }
            }
            return try writeAttributed(text, like: url, to: format)
        default:
            if doc.pageCount == 1 {
                let out = OutputPlacement.destination(for: url, ext: format.ext)
                try ImageConverter.write(try render(doc.page(at: 0)!), to: out, type: format.ext, quality: 0.9)
                return out
            }
            return try pagesToImages(url, ext: format.ext)
        }
    }

    static func render(_ page: PDFPage, scale: CGFloat = 2) throws -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let size = NSSize(width: box.width * scale, height: box.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ConversionError.failed("Could not render page.")
        }
        return cg
    }

    static func pagesToImages(_ url: URL, ext: String = "png") throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url) }
        let folder = OutputPlacement.destination(for: url, ext: "", suffix: " pages")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<doc.pageCount {
            let file = folder.appendingPathComponent(String(format: "Page %03d", i + 1)).appendingPathExtension(ext)
            try ImageConverter.write(try render(doc.page(at: i)!), to: file, type: ext, quality: 0.9)
        }
        return folder
    }

    static func split(_ url: URL) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url) }
        let folder = OutputPlacement.destination(for: url, ext: "", suffix: " split")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        for i in 0..<doc.pageCount {
            let single = PDFDocument()
            if let page = doc.page(at: i)?.copy() as? PDFPage { single.insert(page, at: 0) }
            single.write(to: folder.appendingPathComponent("\(base) – page \(i + 1).pdf"))
        }
        return folder
    }

    static func merge(_ urls: [URL]) throws -> URL {
        let merged = PDFDocument()
        for url in urls.sortedByName {
            guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url) }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        let folder = Settings.shared.outputFolder ?? urls[0].deletingLastPathComponent()
        let out = OutputPlacement.uniqueURL(in: folder, base: "Merged", ext: "pdf")
        guard merged.write(to: out) else { throw ConversionError.failed("Could not write merged PDF.") }
        return out
    }

    /// One page per image, in name order.
    static func pdf(fromImages urls: [URL]) throws -> URL {
        let doc = PDFDocument()
        for url in urls.sortedByName {
            guard let page = PDFPage(image: NSImage(cgImage: try ImageConverter.cgImage(url), size: .zero)) else {
                throw ConversionError.failed("Could not build PDF page.")
            }
            doc.insert(page, at: doc.pageCount)
        }
        let folder = Settings.shared.outputFolder ?? urls[0].deletingLastPathComponent()
        let out = OutputPlacement.uniqueURL(in: folder, base: "Images", ext: "pdf")
        guard doc.write(to: out) else { throw ConversionError.failed("Could not write PDF.") }
        return out
    }

    /// Copy with the pages in `order` (0-based); pages left out are dropped.
    static func organize(_ url: URL, order: [Int]) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url) }
        let result = PDFDocument()
        for i in order {
            if let page = doc.page(at: i)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
        }
        guard result.pageCount > 0 else { throw ConversionError.failed("Keep at least one page.") }
        let out = OutputPlacement.destination(for: url, ext: "pdf", suffix: " organized")
        guard result.write(to: out) else { throw ConversionError.failed("Could not write PDF.") }
        return out
    }

    /// Copy without title, author, subject, keywords, creator or dates.
    static func stripMetadata(_ url: URL) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url) }
        doc.documentAttributes = [:]
        let out = OutputPlacement.destination(for: url, ext: "pdf", suffix: " clean")
        guard doc.write(to: out) else { throw ConversionError.failed("Could not write PDF.") }
        return out
    }

    static func compress(_ url: URL) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url) }
        let out = OutputPlacement.destination(for: url, ext: "pdf", suffix: " compressed")
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard doc.write(to: out, withOptions: options) else { throw ConversionError.failed("Could not compress PDF.") }
        return out
    }

    static func loadText(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown"].contains(ext) {
            let raw = try String(contentsOf: url, encoding: .utf8)
            let md = try AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return NSAttributedString(md)
        }
        if ["txt", "json", "csv"].contains(ext) {
            let raw = try String(contentsOf: url, encoding: .utf8)
            return NSAttributedString(string: raw, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)])
        }
        return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
    }

    static func fromText(_ url: URL, to format: ConversionFormat) throws -> URL {
        let text = try loadText(url)
        switch format {
        case .pdf:
            let out = OutputPlacement.destination(for: url, ext: "pdf")
            try paginatedPDF(text).write(to: out)
            return out
        case .png:
            let pdf = try paginatedPDF(text)
            guard let doc = PDFDocument(data: pdf), let page = doc.page(at: 0) else { throw ConversionError.failed("Render failed.") }
            let out = OutputPlacement.destination(for: url, ext: "png")
            try ImageConverter.write(try render(page), to: out, type: "png", quality: 1)
            return out
        default:
            return try writeAttributed(text, like: url, to: format)
        }
    }

    static func writeAttributed(_ text: NSAttributedString, like url: URL, to format: ConversionFormat) throws -> URL {
        let out = OutputPlacement.destination(for: url, ext: format.ext)
        let range = NSRange(location: 0, length: text.length)
        let type: NSAttributedString.DocumentType
        switch format {
        case .html: type = .html
        case .rtf: type = .rtf
        case .docx: type = .officeOpenXML
        default:
            try text.string.write(to: out, atomically: true, encoding: .utf8)
            return out
        }
        let data = try text.data(from: range, documentAttributes: [.documentType: type])
        try data.write(to: out)
        return out
    }

    /// Lays text out across US Letter pages with 54 pt margins using Core Text.
    static func paginatedPDF(_ text: NSAttributedString) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ConversionError.failed("Could not create PDF context.")
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let frameRect = mediaBox.insetBy(dx: 54, dy: 54)
        var index = 0
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: index, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length == 0 { break }
            index += visible.length
        } while index < text.length
        ctx.closePDF()
        return data as Data
    }
}

// MARK: - Subtitles

enum SubtitleConverter {
    struct Cue { var start: String; var end: String; var text: String }

    static func parse(_ raw: String) -> [Cue] {
        let blocks = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let parts = lines[timing].components(separatedBy: "-->")
            let start = parts[0].trimmingCharacters(in: .whitespaces)
            let end = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]
            let text = lines[(timing + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return Cue(start: start, end: end, text: text)
        }
    }

    static func normalize(_ time: String, comma: Bool) -> String {
        var t = time
        if t.filter({ $0 == ":" }).count == 1 { t = "00:" + t }
        return comma ? t.replacingOccurrences(of: ".", with: ",") : t.replacingOccurrences(of: ",", with: ".")
    }

    static func render(_ cues: [Cue], as format: ConversionFormat) -> String {
        switch format {
        case .vtt:
            return "WEBVTT\n\n" + cues.map { "\(normalize($0.start, comma: false)) --> \(normalize($0.end, comma: false))\n\($0.text)" }
                .joined(separator: "\n\n") + "\n"
        case .srt:
            return cues.enumerated().map { "\($0.offset + 1)\n\(normalize($0.element.start, comma: true)) --> \(normalize($0.element.end, comma: true))\n\($0.element.text)" }
                .joined(separator: "\n\n") + "\n"
        default:
            return cues.map(\.text).joined(separator: "\n") + "\n"
        }
    }

    static func convert(_ url: URL, to format: ConversionFormat) throws -> URL {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let out = OutputPlacement.destination(for: url, ext: format.ext)
        try render(parse(raw), as: format).write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

// MARK: - Archives

enum ArchiveConverter {
    static func convert(_ urls: [URL], to format: ConversionFormat) throws -> URL {
        let first = urls[0]
        let folder = Settings.shared.outputFolder ?? first.deletingLastPathComponent()
        switch format {
        case .folder:
            return try extract(first)
        case .tgz:
            let base = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
            let out = OutputPlacement.uniqueURL(in: folder, base: base, ext: "tar.gz")
            try Shell.run("/usr/bin/tar", ["-czf", out.path, "-C", first.deletingLastPathComponent().path, "--"] + urls.map(\.lastPathComponent))
            return out
        default:
            let base = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
            let out = OutputPlacement.uniqueURL(in: folder, base: base, ext: "zip")
            if urls.count == 1 {
                try Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path])
            } else {
                try Shell.run("/usr/bin/zip", ["-q", "-r", out.path, "--"] + urls.map(\.lastPathComponent),
                              cwd: first.deletingLastPathComponent())
            }
            return out
        }
    }

    /// Unpacks ZIP/TAR/TGZ/RAR (via bsdtar) or a plain .gz into a new folder beside the archive.
    static func extract(_ url: URL) throws -> URL {
        let name = url.lastPathComponent
        let isTarGz = name.lowercased().hasSuffix(".tar.gz")
        let base = isTarGz ? String(name.dropLast(7)) : url.deletingPathExtension().lastPathComponent
        let out = OutputPlacement.uniqueURL(in: Settings.shared.outputFolder ?? url.deletingLastPathComponent(), base: base, ext: "")
        if url.pathExtension.lowercased() == "gz", !isTarGz {
            // A plain gzip holds one file; gunzip a copy inside the new folder.
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let copy = out.appendingPathComponent(name)
            try FileManager.default.copyItem(at: url, to: copy)
            try Shell.run("/usr/bin/gunzip", [copy.path])
            return out
        }
        // Zip-slip guard: refuse the whole archive before anything is written.
        let entries = try Shell.run("/usr/bin/tar", ["-tf", url.path]).split(separator: "\n").map(String.init)
        if let bad = entries.first(where: { !isSafeEntry($0) }) {
            throw ConversionError.failed("Refusing to extract \(name): unsafe path \"\(bad)\".")
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // No -P: bsdtar also refuses to write through symlinks or follow ".." in link targets.
        // On macOS it folds Finder's __MACOSX entries into xattrs, like ditto did.
        try Shell.run("/usr/bin/tar", ["-xf", url.path, "-C", out.path])
        return out
    }

    /// True when an archive entry stays inside the extraction folder: relative and without "..".
    static func isSafeEntry(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
    }
}

extension Array where Element == URL {
    /// Finder-style name order (2 before 10), used wherever several files become one.
    var sortedByName: [URL] {
        sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

// MARK: - Process helper

enum Shell {
    @discardableResult
    static func run(_ tool: String, _ args: [String], cwd: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        let errPipe = Pipe(), outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe
        try process.run()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ConversionError.failed("\((tool as NSString).lastPathComponent) failed: \(message)")
        }
        return String(data: out, encoding: .utf8) ?? ""
    }
}
