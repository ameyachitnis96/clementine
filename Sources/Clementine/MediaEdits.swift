import AppKit
import AVFoundation
import CoreImage

/// A crop region in normalized coordinates (0...1), origin at the top-left of the
/// displayed (orientation-corrected) image or video frame.
struct CropRect: Equatable {
    var x: Double, y: Double, width: Double, height: Double

    static let full = CropRect(x: 0, y: 0, width: 1, height: 1)

    /// Integer pixel rect inside a canvas of `size`, top-left origin. Never empty.
    func pixels(in size: CGSize) -> CGRect {
        let px = (x * size.width).rounded(), py = (y * size.height).rounded()
        let pw = max(1, min((width * size.width).rounded(), size.width - px))
        let ph = max(1, min((height * size.height).rounded(), size.height - py))
        return CGRect(x: px, y: py, width: pw, height: ph)
    }

    /// Parses "x,y,w,h" (normalized) for the CLI.
    init?(string: String) {
        let v = string.split(separator: ",").compactMap { Double($0) }
        guard v.count == 4, v[2] > 0, v[3] > 0, v[0] >= 0, v[1] >= 0, v[0] + v[2] <= 1.0001, v[1] + v[3] <= 1.0001 else { return nil }
        self.init(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

extension ImageConverter {
    static func crop(_ url: URL, to rect: CropRect) throws -> URL {
        let image = try cgImage(url)
        let pixels = rect.pixels(in: CGSize(width: image.width, height: image.height))
        guard let cropped = image.cropping(to: pixels) else { throw ConversionError.failed("Could not crop image.") }
        let ext = writableExt(url)
        let out = OutputPlacement.destination(for: url, ext: ext, suffix: " cropped")
        try write(cropped, to: out, type: ext, quality: Settings.shared.quality)
        return out
    }
}

extension MediaConverter {
    /// Output container for edits that keep the source's kind of media.
    static func editTarget(for url: URL, hasVideo: Bool) -> (ext: String, type: AVFileType) {
        let ext = url.pathExtension.lowercased()
        if hasVideo { return ext == "mov" ? ("mov", .mov) : ("mp4", .mp4) }
        return ("m4a", .m4a)
    }

    /// Cuts `start...end` (seconds). Video is copied without re-encoding where the format allows.
    static func trim(_ url: URL, start: Double, end: Double) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let s = max(0, min(start, duration)), e = max(s, min(end, duration))
        guard e - s >= 0.05 else { throw ConversionError.failed("Selection is too short.") }
        let hasVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
        let target = editTarget(for: url, hasVideo: hasVideo)
        let out = OutputPlacement.destination(for: url, ext: target.ext, suffix: " trimmed")
        let range = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                                end: CMTime(seconds: e, preferredTimescale: 600))
        try await exportEdit(asset, to: out, type: target.type, hasVideo: hasVideo) { $0.timeRange = range }
        return out
    }

    /// Writes an edited copy, copying streams where the container allows and re-encoding otherwise.
    static func exportEdit(_ asset: AVAsset, to out: URL, type: AVFileType, hasVideo: Bool,
                           configure: ((AVAssetExportSession) -> Void)? = nil) async throws {
        let presets = hasVideo ? [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
                               : [AVAssetExportPresetAppleM4A]
        var lastError: Error?
        for preset in presets {
            do {
                try? FileManager.default.removeItem(at: out) // our own partial output from the previous preset
                try await export(asset, preset: preset, to: out, type: type, configure: configure)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ConversionError.failed("Export failed.")
    }

    /// Copy of the video with every audio track dropped.
    static func mute(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        for track in try await asset.loadTracks(withMediaType: .video) {
            let range = try await track.load(.timeRange)
            let copy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try copy?.insertTimeRange(range, of: track, at: range.start)
            copy?.preferredTransform = try await track.load(.preferredTransform)
        }
        guard !composition.tracks.isEmpty else { throw ConversionError.failed("No video track found.") }
        let target = editTarget(for: url, hasVideo: true)
        let out = OutputPlacement.destination(for: url, ext: target.ext, suffix: " muted")
        try await exportEdit(composition, to: out, type: target.type, hasVideo: true)
        return out
    }

    /// Mono (1) or stereo (2) copy. PCM files stay PCM; everything else becomes AAC .m4a.
    static func channels(_ url: URL, count: Int) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        let pcmTypes: [String: AVFileType] = ["wav": .wav, "aif": .aiff, "aiff": .aiff, "caf": .caf]
        let out = OutputPlacement.destination(for: url, ext: pcmTypes[ext] == nil ? "m4a" : ext,
                                              suffix: count == 1 ? " mono" : " stereo")
        try await transcodeAudio(url, to: out, fileType: pcmTypes[ext] ?? .m4a, channels: count,
                                 bitRate: pcmTypes[ext] == nil ? 96_000 * count : nil)
        return out
    }

    /// AAC at 96 kbps.
    static func compressAudio(_ url: URL) async throws -> URL {
        let out = OutputPlacement.destination(for: url, ext: "m4a", suffix: " compressed")
        try await transcodeAudio(url, to: out, fileType: .m4a, bitRate: 96_000)
        return out
    }

    /// Cuts the file at `points` (seconds) into numbered clips inside a new folder.
    static func split(_ url: URL, at points: [Double]) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let cuts = [0] + points.filter { $0 > 0.05 && $0 < duration - 0.05 }.sorted() + [duration]
        guard cuts.count > 2 else { throw ConversionError.failed("Add a split point first.") }
        let hasVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
        let target = editTarget(for: url, hasVideo: hasVideo)
        let folder = OutputPlacement.destination(for: url, ext: "", suffix: " split")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        for i in 0..<(cuts.count - 1) {
            let range = CMTimeRange(start: CMTime(seconds: cuts[i], preferredTimescale: 600),
                                    end: CMTime(seconds: cuts[i + 1], preferredTimescale: 600))
            let out = folder.appendingPathComponent("\(base) \(i + 1)").appendingPathExtension(target.ext)
            try await exportEdit(asset, to: out, type: target.type, hasVideo: hasVideo) { $0.timeRange = range }
        }
        return folder
    }

    /// Plays the videos back to back (name order) in one MP4.
    /// shortcut: clips keep the first clip's size and rotation; add a video composition if mixed sizes matter.
    static func join(_ urls: [URL]) async throws -> URL {
        let composition = AVMutableComposition()
        let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        for url in urls.sortedByName {
            let asset = AVURLAsset(url: url)
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let range = try await track.load(.timeRange)
                try video?.insertTimeRange(range, of: track, at: cursor + range.start)
                if cursor == .zero { video?.preferredTransform = try await track.load(.preferredTransform) }
            }
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                let range = try await track.load(.timeRange)
                try audio?.insertTimeRange(range, of: track, at: cursor + range.start)
            }
            cursor = cursor + (try await asset.load(.duration))
        }
        if let audio, audio.segments.isEmpty { composition.removeTrack(audio) }
        let folder = Settings.shared.outputFolder ?? urls[0].deletingLastPathComponent()
        let out = OutputPlacement.uniqueURL(in: folder, base: "Joined", ext: "mp4")
        try await export(composition, preset: AVAssetExportPresetHighestQuality, to: out, type: .mp4)
        return out
    }

    /// A 1280×720 MP4 of the waveform with a moving playhead, over the original audio.
    static func visualize(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let sound = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.failed("\(url.lastPathComponent) has no audio track.")
        }
        let duration = try await asset.load(.duration)
        let bars = try await waveform(url, buckets: 120)
        let width = 1280, height = 720, fps: Int32 = 15
        let frames = tmpVideo(), writer = try AVAssetWriter(outputURL: frames, fileType: .mov)
        defer { try? FileManager.default.removeItem(at: frames) }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let count = max(1, Int(duration.seconds * Double(fps)))
        for i in 0..<count {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                throw ConversionError.failed("Could not render waveform frame.")
            }
            drawWaveform(bars, progress: Double(i) / Double(count), into: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ConversionError.failed(writer.error?.localizedDescription ?? "Could not render waveform.")
        }
        // Mux the rendered frames with the original sound.
        let rendered = AVURLAsset(url: frames)
        let composition = AVMutableComposition()
        if let track = try await rendered.loadTracks(withMediaType: .video).first {
            try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
                .insertTimeRange(try await track.load(.timeRange), of: track, at: .zero)
        }
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(try await sound.load(.timeRange), of: sound, at: .zero)
        let out = OutputPlacement.destination(for: url, ext: "mp4", suffix: " waveform")
        try await export(composition, preset: AVAssetExportPresetHighestQuality, to: out, type: .mp4)
        return out
    }

    private static func tmpVideo() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
    }

    private static func drawWaveform(_ bars: [Float], progress: Double, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let margin = CGFloat(w) * 0.06, step = (CGFloat(w) - margin * 2) / CGFloat(max(bars.count, 1))
        let played = CGColor(red: 1, green: 0.55, blue: 0.12, alpha: 1), ahead = CGColor(gray: 0.45, alpha: 1)
        for (i, v) in bars.enumerated() {
            let barHeight = max(4, CGFloat(v) * CGFloat(h) * 0.6)
            ctx.setFillColor(Double(i) / Double(bars.count) < progress ? played : ahead)
            ctx.fill(CGRect(x: margin + CGFloat(i) * step + step * 0.15, y: (CGFloat(h) - barHeight) / 2,
                            width: step * 0.7, height: barHeight))
        }
    }

    /// Replaces each range (seconds) with a 1 kHz tone.
    static func bleep(_ url: URL, ranges: [ClosedRange<Double>]) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let sound = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.failed("\(url.lastPathComponent) has no audio track.")
        }
        let duration = try await asset.load(.duration).seconds
        // Clamp and merge overlaps so tone segments never overlap in the beep track.
        var merged: [ClosedRange<Double>] = []
        for r in ranges.map({ max(0, $0.lowerBound)...min(duration, $0.upperBound) }).sorted(by: { $0.lowerBound < $1.lowerBound })
        where r.upperBound - r.lowerBound > 0.01 {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        guard let longest = merged.map({ $0.upperBound - $0.lowerBound }).max() else {
            throw ConversionError.failed("Add a range to bleep first.")
        }
        let tone = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: tone) }
        try writeTone(to: tone, seconds: longest + 0.1)
        let toneAsset = AVURLAsset(url: tone) // tracks only weakly reference their asset
        guard let toneTrack = try await toneAsset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.failed("Could not build the bleep tone.")
        }
        let composition = AVMutableComposition()
        let main = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        try main?.insertTimeRange(try await sound.load(.timeRange), of: sound, at: .zero)
        let beeps = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let volume = AVMutableAudioMixInputParameters(track: main)
        for r in merged {
            let start = CMTime(seconds: r.lowerBound, preferredTimescale: 44_100)
            let length = CMTime(seconds: r.upperBound - r.lowerBound, preferredTimescale: 44_100)
            try beeps?.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: toneTrack, at: start)
            volume.setVolume(0, at: start)
            volume.setVolume(1, at: start + length)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [volume]
        let out = OutputPlacement.destination(for: url, ext: "m4a", suffix: " bleeped")
        try await export(composition, preset: AVAssetExportPresetAppleM4A, to: out, type: .m4a) { $0.audioMix = mix }
        return out
    }

    private static func writeTone(to url: URL, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let frames = AVAudioFrameCount(seconds * 44_100)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw ConversionError.failed("Could not build the bleep tone.")
        }
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = 0.3 * sin(2 * .pi * 1000 * Float(i) / 44_100) }
        // The file is finalized when AVAudioFile deallocates; drain so that happens before it is read.
        try autoreleasepool { try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer) }
    }

    /// Crops every video frame to `rect` (normalized, top-left origin, after rotation).
    static func crop(_ url: URL, to rect: CropRect) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.failed("No video track found.")
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let shown = natural.applying(transform)
        let size = CGSize(width: abs(shown.width), height: abs(shown.height))
        let pixels = rect.pixels(in: size)
        // Even dimensions keep H.264/HEVC encoders happy.
        let cropW = max(2, floor(pixels.width / 2) * 2), cropH = max(2, floor(pixels.height / 2) * 2)
        // Core Image uses a bottom-left origin.
        let ciRect = CGRect(x: pixels.minX, y: size.height - pixels.minY - cropH, width: cropW, height: cropH)
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let image = request.sourceImage.cropped(to: ciRect)
                .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
            request.finish(with: image, context: nil)
        }
        composition.renderSize = CGSize(width: cropW, height: cropH)
        let target = editTarget(for: url, hasVideo: true)
        let out = OutputPlacement.destination(for: url, ext: target.ext, suffix: " cropped")
        try await export(asset, preset: AVAssetExportPresetHighestQuality, to: out, type: target.type) {
            $0.videoComposition = composition
        }
        return out
    }

    /// Peak amplitude per bucket (0...1) for drawing a waveform.
    static func waveform(_ url: URL, buckets: Int = 160) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: length / 2)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            // Decimate early so long files stay cheap.
            samples.append(contentsOf: stride(from: 0, to: chunk.count, by: 16).map { chunk[$0] })
        }
        guard !samples.isEmpty else { return [] }
        let per = max(1, samples.count / buckets)
        return stride(from: 0, to: samples.count, by: per).prefix(buckets).map { i in
            let slice = samples[i..<min(i + per, samples.count)]
            return Float(slice.map { abs(Int($0)) }.max() ?? 0) / Float(Int16.max)
        }
    }
}
