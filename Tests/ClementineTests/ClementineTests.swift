import Foundation
import Testing
@testable import Clementine

struct ClementineTests {
    @Test func testMatrixGroupsAndOutputs() {
        #expect(FormatCompatibilityMatrix.group(for: URL(fileURLWithPath: "/a/photo.heic")) == .image)
        #expect(FormatCompatibilityMatrix.group(for: URL(fileURLWithPath: "/a/clip.mov")) == .video)
        #expect(FormatCompatibilityMatrix.group(for: URL(fileURLWithPath: "/a/song.wav")) == .audio)
        #expect(FormatCompatibilityMatrix.group(for: URL(fileURLWithPath: "/a/doc.pdf")) == .document)
        #expect(FormatCompatibilityMatrix.group(for: URL(fileURLWithPath: "/a/subs.srt")) == .subtitle)
        let outs = FormatCompatibilityMatrix.outputs(for: URL(fileURLWithPath: "/a/photo.png"))
        #expect(!outs.contains(.png), "never offer the input format")
        #expect(outs.contains(.jpeg))
    }

    @Test @MainActor func testFanHitTesting() {
        let model = FanModel()
        model.items = (0..<4).map { _ in FanAction.tool(.zip) }
        let c = FanModel.size / 2
        #expect(model.index(at: CGPoint(x: c, y: c)) == nil, "hub cancels")
        #expect(model.index(at: CGPoint(x: c, y: c + 120)) == 0, "12 o'clock")
        #expect(model.index(at: CGPoint(x: c + 120, y: c)) == 1, "3 o'clock")
        #expect(model.index(at: CGPoint(x: c, y: c - 120)) == 2, "6 o'clock")
        #expect(model.index(at: CGPoint(x: c - 120, y: c)) == 3, "9 o'clock")
    }

    @Test func testSubtitleRoundTrip() {
        let srt = "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\n"
        let cues = SubtitleConverter.parse(srt)
        #expect(cues.count == 2)
        let vtt = SubtitleConverter.render(cues, as: .vtt)
        #expect(vtt.hasPrefix("WEBVTT"))
        #expect(vtt.contains("00:00:01.000 --> 00:00:02.500"))
        #expect(SubtitleConverter.render(SubtitleConverter.parse(vtt), as: .srt) == srt)
    }

    @Test func testUniqueOutputNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = OutputPlacement.uniqueURL(in: dir, base: "x", ext: "png")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        #expect(OutputPlacement.uniqueURL(in: dir, base: "x", ext: "png").lastPathComponent == "x 2.png")
    }
}

struct EditingTests {
    @Test func cropRectPixels() {
        let r = CropRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5).pixels(in: CGSize(width: 400, height: 200))
        #expect(r == CGRect(x: 100, y: 100, width: 200, height: 100))
        #expect(CropRect(string: "0,0,1,1") == .full)
        #expect(CropRect(string: "0.5,0,0.6,1") == nil, "must stay inside the frame")
        #expect(CropRect(string: "nope") == nil)
    }

    @Test @MainActor func cropAspectLockKeepsRatioAndBounds() async throws {
        let model = CropModel(url: URL(fileURLWithPath: "/nonexistent.png"))
        model.pixelSize = CGSize(width: 1600, height: 900)
        model.aspect = .square
        var px = model.rect.pixels(in: model.pixelSize)
        #expect(abs(px.width - px.height) <= 1)
        #expect(px.height == 900, "largest centered square")
        model.drag(.bottomRight, translation: CGSize(width: 0.5, height: 0.5))
        model.endDrag()
        px = model.rect.pixels(in: model.pixelSize)
        #expect(abs(px.width - px.height) <= 1)
        #expect(model.rect.x + model.rect.width <= 1.0001 && model.rect.y + model.rect.height <= 1.0001)
        model.aspect = .free
        model.drag(.move, translation: CGSize(width: -2, height: -2))
        #expect(model.rect.x == 0 && model.rect.y == 0, "move clamps to the frame")
    }

    @Test func toolsOfferEditorsForSingleMedia() {
        let video = FileTool.tools(for: [URL(fileURLWithPath: "/a/clip.mov")])
        #expect(video.contains(.crop) && video.contains(.trim))
        let audio = FileTool.tools(for: [URL(fileURLWithPath: "/a/song.wav")])
        #expect(audio.contains(.trim) && !audio.contains(.crop))
        let photos = FileTool.tools(for: [URL(fileURLWithPath: "/a/1.png"), URL(fileURLWithPath: "/a/2.png")])
        #expect(!photos.contains(.crop), "editors take one file")
    }

    @Test @MainActor func shelfDeduplicatesAndRemoves() {
        let shelf = ShelfModel()
        let a = URL(fileURLWithPath: "/tmp"), b = URL(fileURLWithPath: "/usr")
        shelf.add([a, b, a])
        #expect(shelf.urls == [a, b])
        shelf.remove([a])
        #expect(shelf.urls == [b])
    }
}
