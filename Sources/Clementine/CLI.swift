import Foundation

/// Headless entry point that runs the same engine the fan uses.
enum CLI {
    static let modes: Set<String> = ["--convert", "--tool", "--crop", "--trim"]

    static func run(_ args: [String]) -> Int32 {
        if args[1] == "--crop" || args[1] == "--trim" { return runEdit(args) }
        let urls = args.dropFirst(3).map { URL(fileURLWithPath: $0) }
        let action: FanAction
        if args[1] == "--convert" {
            guard let format = FormatCompatibilityMatrix.outputs(for: urls[0]).first(where: { $0.ext == args[2] || $0.label.lowercased() == args[2].lowercased() }) else {
                let offered = FormatCompatibilityMatrix.outputs(for: urls[0]).map(\.ext).joined(separator: ", ")
                FileHandle.standardError.write(Data("Unsupported target \(args[2]). Offered: \(offered)\n".utf8))
                return 2
            }
            action = .convert(format)
        } else {
            guard let tool = FileTool(rawValue: args[2]) else {
                let names = FileTool.allCases.map(\.rawValue).joined(separator: ", ")
                FileHandle.standardError.write(Data("Unknown tool \(args[2]). Tools: \(names)\n".utf8))
                return 2
            }
            if tool == .readQR {
                // The GUI shows an alert; headless mode prints payloads instead.
                do {
                    for payload in try urls.flatMap(QRReader.read) { print(payload) }
                    return 0
                } catch {
                    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                    return 1
                }
            }
            action = .tool(tool)
        }
        return wait { try await ActionRunner.perform(action, on: urls) }
    }

    /// --crop x,y,w,h <file>   (normalized, top-left origin)
    /// --trim <start> <end> <file>   (seconds)
    static func runEdit(_ args: [String]) -> Int32 {
        if args[1] == "--crop" {
            guard let rect = CropRect(string: args[2]) else {
                FileHandle.standardError.write(Data("Crop rect must be x,y,w,h in 0...1\n".utf8))
                return 2
            }
            let url = URL(fileURLWithPath: args[3])
            let isVideo = FormatCompatibilityMatrix.group(for: url) == .video
            return wait { [isVideo ? try await MediaConverter.crop(url, to: rect) : try ImageConverter.crop(url, to: rect)] }
        }
        guard args.count >= 5, let start = Double(args[2]), let end = Double(args[3]) else {
            FileHandle.standardError.write(Data("Usage: --trim <start> <end> <file>\n".utf8))
            return 2
        }
        let url = URL(fileURLWithPath: args[4])
        return wait { [try await MediaConverter.trim(url, start: start, end: end)] }
    }

    private static func wait(_ work: @escaping () async throws -> [URL]) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        Task.detached {
            do {
                for out in try await work() { print(out.path) }
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                status = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        return status
    }
}
