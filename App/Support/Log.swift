import Foundation

/// Appends JSON lines to logs/agentos-<launch>.jsonl and mirrors them to stdout.
nonisolated enum Log {
    nonisolated(unsafe) private static var handle: FileHandle?
    private static let queue = DispatchQueue(label: "dev.agentos.log")

    static let fileURL: URL = {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return Paths.logs.appendingPathComponent("agentos-\(stamp).jsonl")
    }()

    static func event(_ kind: String, _ fields: [String: JSON] = [:]) {
        var record = fields
        record["t"] = .string(ISO8601DateFormatter().string(from: Date()))
        record["kind"] = .string(kind)
        let line = JSON.object(record).text() + "\n"
        queue.async {
            if handle == nil {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                handle = try? FileHandle(forWritingTo: fileURL)
            }
            handle?.write(Data(line.utf8))
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }

    static func info(_ message: String) {
        event("info", ["message": .string(message)])
    }

    static func error(_ message: String) {
        event("error", ["message": .string(message)])
    }
}
