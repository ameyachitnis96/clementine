import AppKit
import AVFoundation
import Foundation
import PDFKit
import Testing
@testable import Clementine

/// Small generated inputs so tool tests need no checked-in media.
enum Fixtures {
    static func dir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Stereo (or mono) sine as a float WAV.
    static func tone(in dir: URL, seconds: Double = 1, channels: AVAudioChannelCount = 2) throws -> URL {
        let url = dir.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: channels)!
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = 0.5 * sin(Float(i) * 0.06) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    static func png(in dir: URL, name: String, width: Int, height: Int) throws -> URL {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        try ImageConverter.write(ctx.makeImage()!, to: url, type: "png", quality: 1)
        return url
    }

    static func channels(_ url: URL) async throws -> Int {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
        let desc = try #require(try await track.load(.formatDescriptions).first)
        return Int(CMAudioFormatDescriptionGetStreamBasicDescription(desc)!.pointee.mChannelsPerFrame)
    }

    static func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}

struct ToolTests {
    @Test func toolsOfferedPerType() {
        #expect(FileTool.tools(for: [URL(fileURLWithPath: "/a/x.zip")]) == [.extract])
        #expect(FileTool.tools(for: [URL(fileURLWithPath: "/a/x.rar")]) == [.extract])
        #expect(FileTool.tools(for: [URL(fileURLWithPath: "/a/folder", isDirectory: true)]).isEmpty, "folders are not archives")
        let photos = FileTool.tools(for: [URL(fileURLWithPath: "/a/1.png"), URL(fileURLWithPath: "/a/2.png")])
        #expect(photos.contains(.createPDF))
        #expect(!FileTool.tools(for: [URL(fileURLWithPath: "/a/1.png")]).contains(.createPDF))
        let audio = FileTool.tools(for: [URL(fileURLWithPath: "/a/song.wav")])
        #expect(audio.contains(.toMono) && audio.contains(.toStereo) && audio.contains(.removeMetadata) && audio.contains(.compress))
        let clip = FileTool.tools(for: [URL(fileURLWithPath: "/a/clip.mov")])
        #expect(clip.contains(.mute) && clip.contains(.splitVideo) && clip.contains(.redact) && !clip.contains(.join))
        let clips = FileTool.tools(for: [URL(fileURLWithPath: "/a/1.mov"), URL(fileURLWithPath: "/a/2.mp4")])
        #expect(clips.contains(.join) && !clips.contains(.splitVideo) && !clips.contains(.redact))
        #expect(audio.contains(.visualize) && audio.contains(.bleep))
        #expect(FileTool.tools(for: [URL(fileURLWithPath: "/a/doc.pdf")]).contains(.removeMetadata))
    }

    @Test func extractEntryCheck() {
        #expect(ArchiveConverter.isSafeEntry("a/b.txt"))
        #expect(ArchiveConverter.isSafeEntry("./a/..b"), "a name starting with .. is not traversal")
        #expect(!ArchiveConverter.isSafeEntry("../evil"))
        #expect(!ArchiveConverter.isSafeEntry("a/../../evil"))
        #expect(!ArchiveConverter.isSafeEntry("/etc/passwd"))
        #expect(!ArchiveConverter.isSafeEntry("a\\..\\evil"))
    }

    @Test func extractRefusesZipSlipAndUnpacksSafeArchive() throws {
        let dir = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "hi".write(to: src.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let evil = dir.appendingPathComponent("evil.tar")
        try Shell.run("/usr/bin/tar", ["-cf", evil.path, "-C", src.path, "-s", ",^,../,", "f.txt"])
        #expect(throws: ConversionError.self) { try ArchiveConverter.extract(evil) }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("f.txt").path), "nothing escaped")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("evil").path), "nothing written")

        let good = dir.appendingPathComponent("good.tar.gz")
        try Shell.run("/usr/bin/tar", ["-czf", good.path, "-C", src.path, "f.txt"])
        let out = try ArchiveConverter.extract(good)
        #expect(out.lastPathComponent == "good")
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("f.txt").path))
        #expect(FileManager.default.fileExists(atPath: good.path), "original kept")
    }

    @Test func createPDFAndStripPDFMetadata() throws {
        let dir = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let two = try Fixtures.png(in: dir, name: "2.png", width: 40, height: 30)
        let ten = try Fixtures.png(in: dir, name: "10.png", width: 80, height: 60)
        let pdf = try DocumentConverter.pdf(fromImages: [ten, two])
        let doc = try #require(PDFDocument(url: pdf))
        #expect(doc.pageCount == 2)
        #expect(doc.page(at: 0)?.bounds(for: .mediaBox).width == 40, "name order: 2 before 10")

        doc.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Secret", PDFDocumentAttribute.authorAttribute: "Me"]
        let tagged = dir.appendingPathComponent("tagged.pdf")
        #expect(doc.write(to: tagged))
        #expect(PDFDocument(url: tagged)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Secret")
        let clean = try #require(PDFDocument(url: try DocumentConverter.stripMetadata(tagged)))
        #expect(clean.documentAttributes?[PDFDocumentAttribute.titleAttribute] == nil)
        #expect(clean.documentAttributes?[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(clean.pageCount == 2)

        let organized = try #require(PDFDocument(url: try DocumentConverter.organize(pdf, order: [1])))
        #expect(organized.pageCount == 1)
        #expect(organized.page(at: 0)?.bounds(for: .mediaBox).width == 80, "kept page 2, dropped page 1")
        #expect(throws: ConversionError.self) { try DocumentConverter.organize(pdf, order: []) }
    }

    @Test func collageLayouts() {
        let grid = Collage.layout(.grid, count: 4, cell: 100)
        #expect(grid.frames.count == 4 && grid.canvas.width == grid.canvas.height)
        let row = Collage.layout(.row, count: 3, cell: 100)
        #expect(row.canvas.width > row.canvas.height * 2 && Set(row.frames.map(\.minY)).count == 1)
        let column = Collage.layout(.column, count: 3, cell: 100)
        #expect(column.canvas.height > column.canvas.width * 2 && Set(column.frames.map(\.minX)).count == 1)
        let featured = Collage.layout(.featured, count: 3, cell: 100)
        #expect(featured.frames.count == 3 && featured.frames[0].width > featured.frames[1].width * 1.5)
        for layout in [grid, row, column, featured] {
            #expect(layout.frames.allSatisfy { CGRect(origin: .zero, size: layout.canvas).contains($0) })
        }
    }

    @Test func imageEditorsRender() throws {
        let dir = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = try Fixtures.png(in: dir, name: "p.png", width: 100, height: 50)
        let image = try ImageConverter.cgImage(png)

        var bg = BackgroundOptions()
        bg.padding = 0.1
        bg.aspect = .square
        let framed = try #require(bg.render(image))
        #expect(framed.width == 120 && framed.height == 120)

        let dark = try #require(ImageAdjustments(exposure: -2).render(image))
        let brightness = { (cg: CGImage) in NSBitmapImageRep(cgImage: cg).colorAt(x: 50, y: 25)!.brightnessComponent }
        #expect(brightness(dark) < brightness(image))

        let box = Annotation(kind: .box, start: CGPoint(x: 0.2, y: 0.2), end: CGPoint(x: 0.8, y: 0.8),
                             color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let marked = try Annotator.render(png, [box, Annotation(kind: .number, start: CGPoint(x: 0.5, y: 0.5), end: .zero, color: box.color)])
        #expect(marked.lastPathComponent == "p annotated.png")
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: marked)))
        #expect(rep.pixelsWide == 100 && rep.pixelsHigh == 50)
        let edge = try #require(rep.colorAt(x: 50, y: 10)?.usingColorSpace(.sRGB)) // top edge of the box
        #expect(edge.redComponent > 0.8 && edge.blueComponent < 0.3)
    }

    @Test func audioChannelsCompressAndMetadata() async throws {
        let dir = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tone = try Fixtures.tone(in: dir)
        let mono = try await MediaConverter.channels(tone, count: 1)
        #expect(mono.lastPathComponent == "tone mono.wav")
        #expect(try await Fixtures.channels(mono) == 1)
        let stereo = try await MediaConverter.channels(mono, count: 2)
        #expect(try await Fixtures.channels(stereo) == 2)
        let small = try await MediaConverter.compressAudio(tone)
        #expect(small.pathExtension == "m4a" && Fixtures.size(small) < Fixtures.size(tone))
        #expect(try await Fixtures.channels(try await MediaConverter.channels(small, count: 1)) == 1, "AAC mono")

        let tagged = dir.appendingPathComponent("tagged.m4a")
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = "Secret" as NSString
        try await MediaConverter.export(AVURLAsset(url: tone), preset: AVAssetExportPresetAppleM4A, to: tagged, type: .m4a) {
            $0.metadata = [title]
        }
        #expect(!(try await AVURLAsset(url: tagged).load(.commonMetadata)).isEmpty)
        let clean = try await MediaConverter.stripMetadata(tagged)
        #expect(try await AVURLAsset(url: clean).load(.commonMetadata).isEmpty)
    }

    @Test func avTools() async throws {
        let dir = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tone = try Fixtures.tone(in: dir, seconds: 2)
        func tracks(_ url: URL, _ type: AVMediaType) async throws -> Int { try await AVURLAsset(url: url).loadTracks(withMediaType: type).count }
        func seconds(_ url: URL) async throws -> Double { try await AVURLAsset(url: url).load(.duration).seconds }

        let video = try await MediaConverter.visualize(tone)
        #expect(video.lastPathComponent == "tone waveform.mp4")
        #expect(try await tracks(video, .video) == 1)
        #expect(try await tracks(video, .audio) == 1)
        #expect(abs(try await seconds(video) - 2) < 0.2)

        let muted = try await MediaConverter.mute(video)
        #expect(try await tracks(muted, .video) == 1)
        #expect(try await tracks(muted, .audio) == 0)

        let clips = try await MediaConverter.split(video, at: [1.2, 0.5])
        let parts = try FileManager.default.contentsOfDirectory(at: clips, includingPropertiesForKeys: nil).sortedByName
        #expect(parts.map(\.lastPathComponent) == ["tone waveform 1.mp4", "tone waveform 2.mp4", "tone waveform 3.mp4"])
        #expect(abs(try await seconds(parts[0]) - 0.5) < 0.2)
        await #expect(throws: ConversionError.self) { try await MediaConverter.split(video, at: []) }

        let joined = try await MediaConverter.join([parts[1], parts[0]])
        #expect(joined.lastPathComponent == "Joined.mp4")
        #expect(abs(try await seconds(joined) - (try await seconds(parts[0]) + seconds(parts[1]))) < 0.2)

        let clean = try await MediaConverter.stripMetadata(video)
        #expect(try await tracks(clean, .video) == 1)
        #expect(try await tracks(clean, .audio) == 1)

        let bleeped = try await MediaConverter.bleep(tone, ranges: [0.2...0.6, 0.5...0.9, 1.5...5])
        #expect(try await tracks(bleeped, .audio) == 1, "tone track is mixed in")
        #expect(abs(try await seconds(bleeped) - 2) < 0.2)
        await #expect(throws: ConversionError.self) { try await MediaConverter.bleep(tone, ranges: []) }

        let redacted = try await Redactor.redactVideo(video, options: RedactOptions())
        #expect(redacted.lastPathComponent == "tone waveform redacted.mp4")
        #expect(try await tracks(redacted, .video) == 1)
    }

    @Test func redactFindsTextAndCoversIt() throws {
        let ctx = CGContext(data: nil, width: 800, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 300))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: "SECRET 1234", attributes: [.font: NSFont.boldSystemFont(ofSize: 90)]).draw(at: CGPoint(x: 40, y: 100))
        NSGraphicsContext.current = nil
        let image = CIImage(cgImage: ctx.makeImage()!)
        #expect(try Redactor.regions(in: image, faces: false, text: true).count >= 1)
        #expect(try Redactor.regions(in: image, faces: false, text: false).isEmpty)

        let covered = Redactor.apply(image, regions: [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)], solid: true)
        let cg = try #require(CIContext().createCGImage(covered, from: image.extent))
        let center = try #require(NSBitmapImageRep(cgImage: cg).colorAt(x: 400, y: 150))
        #expect(center.brightnessComponent < 0.05, "solid cover is black")
    }
}
