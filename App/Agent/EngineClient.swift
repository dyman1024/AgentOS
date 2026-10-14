import Foundation

/// Runs the agent engine sidecar and speaks JSON-RPC 2.0 (newline-delimited) with it over stdio.
final class EngineClient {
    enum EngineError: LocalizedError {
        case notRunning
        case remote(String)
        case exited(String)

        var errorDescription: String? {
            switch self {
            case .notRunning: "Agent 引擎未启动"
            case .remote(let m): m
            case .exited(let m): "Agent 引擎已退出：\(m)"
            }
        }
    }

    /// Engine → host notifications (method, params).
    var onNotification: ((String, JSON) -> Void)?
    /// Engine → host requests; the returned value becomes the JSON-RPC result.
    var onRequest: ((String, JSON) async throws -> JSON)?

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var stderrTail: [String] = []

    var isRunning: Bool { process?.isRunning == true }

    /// Starts the engine. `environment` overrides the inherited environment; nil values remove a variable.
    func start(environment overrides: [String: String?]) throws {
        stop()
        let (executable, arguments, claudeBin) = try Self.locateEngine()
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        for (name, value) in overrides { env[name] = value }
        env["CLAUDE_CONFIG_DIR"] = Paths.agentConfig.path
        env["CLAUDE_AGENT_SDK_CLIENT_APP"] = "AgentOS/0.1"
        env["DISABLE_AUTOUPDATER"] = "1"
        if let claudeBin { env["AGENTOS_CLAUDE_BIN"] = claudeBin.path }
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        // Pipe callbacks fire on background threads; hop to the main queue (FIFO keeps message order).
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receiveStderr(data) } }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.didExit(status: status) } }
        }

        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        Log.event("engine_started", ["pid": .number(Double(p.processIdentifier)), "executable": .string(executable.path)])
    }

    func stop() {
        guard let p = process else { return }
        process = nil
        stdin = nil
        if p.isRunning { p.terminate() }
        failPending(EngineError.exited("stopped"))
    }

    func request(_ method: String, _ params: JSON) async throws -> JSON {
        guard stdin != nil else { throw EngineError.notRunning }
        let id = nextId
        nextId += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        }
    }

    func notify(_ method: String, _ params: JSON) {
        send(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    // MARK: - Wire

    private func send(_ message: JSON) {
        guard let stdin else { return }
        var data = message.data()
        data.append(0x0A)
        do { try stdin.write(contentsOf: data) } catch { Log.error("engine write failed: \(error)") }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            do { handle(try JSON.parse(line)) } catch {
                Log.error("engine sent malformed JSON: \(String(decoding: line.prefix(200), as: UTF8.self))")
            }
        }
    }

    private func handle(_ message: JSON) {
        if let method = message["method"]?.string {
            let params = message["params"] ?? .object([:])
            guard let id = message["id"], !id.isNull else {
                onNotification?(method, params)
                return
            }
            Task {
                do {
                    let result = try await self.onRequest?(method, params) ?? .null
                    self.send(["jsonrpc": "2.0", "id": id, "result": result])
                } catch {
                    self.send(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": .string(error.localizedDescription)]])
                }
            }
            return
        }
        guard let id = message["id"]?.int, let continuation = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] {
            continuation.resume(throwing: EngineError.remote(error["message"]?.string ?? "engine error"))
        } else {
            continuation.resume(returning: message["result"] ?? .null)
        }
    }

    private func receiveStderr(_ data: Data) {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            stderrTail.append(String(line))
            Log.event("engine_stderr", ["line": .string(String(line))])
        }
        if stderrTail.count > 40 { stderrTail.removeFirst(stderrTail.count - 40) }
    }

    private func didExit(status: Int32) {
        Log.event("engine_exited", ["status": .number(Double(status))])
        process = nil
        stdin = nil
        let detail = stderrTail.suffix(5).joined(separator: "\n")
        failPending(EngineError.exited("status \(status)\(detail.isEmpty ? "" : "\n" + detail)"))
    }

    private func failPending(_ error: Error) {
        let waiters = pending
        pending.removeAll()
        for (_, c) in waiters { c.resume(throwing: error) }
    }

    // MARK: - Locating the engine

    /// `AGENTOS_ENGINE_CMD` (e.g. "bun run /path/agent-engine/src/index.ts") overrides the bundled engine for development.
    private static func locateEngine() throws -> (URL, [String], URL?) {
        if let cmd = ProcessInfo.processInfo.environment["AGENTOS_ENGINE_CMD"], !cmd.isEmpty {
            let parts = cmd.split(separator: " ").map(String.init)
            return (URL(fileURLWithPath: "/usr/bin/env"), parts, nil)
        }
        guard let resources = Bundle.main.resourceURL else { throw EngineError.notRunning }
        let engine = resources.appendingPathComponent("engine/agentos-engine")
        let claude = resources.appendingPathComponent("engine/claude")
        guard FileManager.default.isExecutableFile(atPath: engine.path) else {
            throw EngineError.remote("找不到 Agent 引擎：\(engine.path)")
        }
        return (engine, [], FileManager.default.isExecutableFile(atPath: claude.path) ? claude : nil)
    }
}
