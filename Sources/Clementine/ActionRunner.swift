import AppKit
import Vision

/// One thing the user picked from the fan.
enum FanAction: Hashable {
    case convert(ConversionFormat)
    case tool(FileTool)

    var label: String {
        switch self {
        case .convert(let f): return f.label
        case .tool(let t): return t.label
        }
    }
}

/// Recent jobs, shown in the menu bar.
@MainActor
final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    struct Record: Identifiable {
        let id = UUID()
        let title: String
        var status: Status
        var output: URL?
        enum Status { case running, done, failed(String) }
    }

    @Published private(set) var records: [Record] = []
    @Published private(set) var completedCount = UserDefaults.standard.integer(forKey: "completedCount")

    func start(_ title: String) -> UUID {
        let record = Record(title: title, status: .running)
        records.insert(record, at: 0)
        records = Array(records.prefix(12))
        return record.id
    }

    func finish(_ id: UUID, output: URL?) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].status = .done
        records[i].output = output
        completedCount += 1
        UserDefaults.standard.set(completedCount, forKey: "completedCount")
    }

    func fail(_ id: UUID, _ message: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].status = .failed(message)
    }
}

/// Runs a fan action. No usage limits: every action is free and unlimited.
@MainActor
enum ActionRunner {
    static func run(_ action: FanAction, on urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch action {
        case .tool(.copyPath):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            Feedback.toast("Copied \(urls.count == 1 ? "path" : "\(urls.count) paths")")
            return
        case .tool(.airDrop):
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
            return
        case .tool(.crop):
            CropEditor.open(urls[0])
            return
        case .tool(.trim):
            TrimEditor.open(urls[0])
            return
        case .tool(.splitVideo):
            TrimEditor.open(urls[0], mode: .split)
            return
        case .tool(.bleep):
            TrimEditor.open(urls[0], mode: .bleep)
            return
        case .tool(.redact):
            RedactEditor.open(urls[0])
            return
        case .tool(.annotate):
            AnnotateEditor.open(urls[0])
            return
        case .tool(.editImage):
            ImageEditors.openEdit(urls[0])
            return
        case .tool(.addBackground):
            ImageEditors.openBackground(urls[0])
            return
        case .tool(.collage):
            CollageEditor.open(urls)
            return
        case .tool(.organizePDF):
            OrganizeEditor.open(urls[0])
            return
        case .tool(.copy):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            Feedback.toast("Copied \(urls.count == 1 ? "file" : "\(urls.count) files")")
            return
        case .tool(.move):
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Move Here"
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            do {
                for url in urls { try FileManager.default.moveItem(at: url, to: dest.appendingPathComponent(url.lastPathComponent)) }
                Feedback.done("Move")
            } catch { Feedback.error(error.localizedDescription) }
            return
        case .tool(.terminal):
            var isDir: ObjCBool = false
            let folder = FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDir) && isDir.boolValue ? urls[0] : urls[0].deletingLastPathComponent()
            NSWorkspace.shared.open([folder], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration())
            return
        case .tool(.addToShelf):
            ShelfController.shared.add(urls)
            return
        default:
            break
        }

        let title = "\(action.label) · \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")"
        let id = TaskStore.shared.start(title)
        Task.detached(priority: .userInitiated) {
            do {
                let outputs = try await perform(action, on: urls)
                await MainActor.run {
                    TaskStore.shared.finish(id, output: outputs.last)
                    if Settings.shared.revealInFinder, let last = outputs.last {
                        NSWorkspace.shared.activateFileViewerSelecting(outputs.isEmpty ? [last] : outputs)
                    }
                    Feedback.done(action.label)
                }
            } catch {
                await MainActor.run {
                    TaskStore.shared.fail(id, error.localizedDescription)
                    Feedback.error(error.localizedDescription)
                }
            }
        }
    }

    nonisolated static func perform(_ action: FanAction, on urls: [URL]) async throws -> [URL] {
        switch action {
        case .convert(let format):
            if format.group == .archive, urls.count > 1 || urls[0].hasDirectoryPath {
                return [try ArchiveConverter.convert(urls, to: format)]
            }
            var outs: [URL] = []
            for url in urls { outs.append(try await ConversionEngine.convert(url, to: format)) }
            return outs
        case .tool(.mergePDFs):
            return [try DocumentConverter.merge(urls)]
        case .tool(.createPDF):
            return [try DocumentConverter.pdf(fromImages: urls)]
        case .tool(.join):
            return [try await MediaConverter.join(urls)]
        case .tool(.zip):
            return [try ArchiveConverter.convert(urls, to: .zip)]
        case .tool(.readQR):
            let results = try urls.flatMap(QRReader.read)
            await MainActor.run { QRReader.present(results) }
            return []
        case .tool(let tool):
            var outs: [URL] = []
            for url in urls { outs.append(try await apply(tool, to: url)) }
            return outs
        }
    }

    nonisolated static func apply(_ tool: FileTool, to url: URL) async throws -> URL {
        let group = FormatCompatibilityMatrix.group(for: url)
        switch tool {
        case .compress:
            switch group {
            case .video: return try await MediaConverter.compressVideo(url)
            case .audio: return try await MediaConverter.compressAudio(url)
            case .document: return try DocumentConverter.compress(url)
            default: return try ImageConverter.compress(url)
            }
        case .removeMetadata:
            switch group {
            case .image: return try ImageConverter.stripMetadata(url)
            case .document: return try DocumentConverter.stripMetadata(url)
            default: return try await MediaConverter.stripMetadata(url)
            }
        case .resizeHalf: return try ImageConverter.resize(url, factor: 0.5)
        case .rotate: return try ImageConverter.rotate(url)
        case .splitPDF: return try DocumentConverter.split(url)
        case .pdfToImages: return try DocumentConverter.pagesToImages(url)
        case .extractAudio: return try await MediaConverter.extractAudio(url)
        case .speedUp: return try await MediaConverter.speed(url, factor: 2)
        case .videoSnapshot: return try await MediaConverter.snapshot(url)
        case .normalizeAudio: return try MediaConverter.normalize(url)
        case .mute: return try await MediaConverter.mute(url)
        case .toMono: return try await MediaConverter.channels(url, count: 1)
        case .toStereo: return try await MediaConverter.channels(url, count: 2)
        case .extract: return try ArchiveConverter.extract(url)
        case .visualize: return try await MediaConverter.visualize(url)
        case .redact: // headless: the GUI opens RedactEditor; the CLI uses the defaults
            return group == .video ? try await Redactor.redactVideo(url, options: RedactOptions())
                                   : try Redactor.redactImage(url, options: RedactOptions())
        // Multi-file tools run in perform; editors need the GUI.
        case .readQR, .mergePDFs, .createPDF, .join, .copyPath, .airDrop, .zip, .crop, .trim, .splitVideo, .bleep,
             .editImage, .annotate, .addBackground, .collage, .organizePDF, .addToShelf, .copy, .move, .terminal:
            throw ConversionError.unsupported(tool.label)
        }
    }
}

enum QRReader {
    static func read(_ url: URL) throws -> [String] {
        let image = try ImageConverter.cgImage(url)
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    @MainActor
    static func present(_ results: [String]) {
        let alert = NSAlert()
        if results.isEmpty {
            alert.messageText = "No QR code found"
        } else {
            alert.messageText = results.count == 1 ? "QR code" : "\(results.count) codes"
            alert.informativeText = results.joined(separator: "\n\n")
            alert.addButton(withTitle: "Copy")
            alert.addButton(withTitle: "Close")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, !results.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(results.joined(separator: "\n"), forType: .string)
        }
    }
}

@MainActor
enum Feedback {
    static func done(_ label: String) {
        if Settings.shared.playSound { NSSound(named: "Glass")?.play() }
        toast("\(label) done")
    }

    static func error(_ message: String) {
        NSSound.beep()
        toast(message, isError: true)
    }

    static func toast(_ message: String, isError: Bool = false) {
        ToastPanel.show(message, isError: isError)
    }
}
