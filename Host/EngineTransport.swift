import AgentOSCore
import Darwin
import Foundation

@MainActor final class EngineTransport {
  var onRequest: ((String, Value) async throws -> Value)?
  var onUpdate: ((Value) -> Void)?
  private var process: Process?, input: FileHandle?, buffer = Data(), next = 0, generation = UUID()
  private var pending: [Int: CheckedContinuation<Value, Error>] = [:]
  private var outgoing: [Data] = [], outgoingBytes = 0, writing = false
  private var hostRequests = 0
  var running: Bool { process?.isRunning == true }
  func start(root: URL, environment: [String: String]) throws {
    stop()
    let generation = UUID()
    self.generation = generation
    let resources = Bundle.main.resourceURL!
    let exe = resources.appendingPathComponent("engine/agentos-engine")
    let claude = resources.appendingPathComponent("engine/claude")
    guard FileManager.default.isExecutableFile(atPath: exe.path) else {
      throw HostError("unavailable", "找不到 Agent 引擎")
    }
    let p = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    p.executableURL = exe
    #if DEBUG
      if let command = ProcessInfo.processInfo.environment["AGENTOS_ENGINE_CMD"], !command.isEmpty {
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
      }
    #endif
    p.currentDirectoryURL = root
    var env: [String: String] = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
      "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8",
      "CLAUDE_CONFIG_DIR": root.appendingPathComponent("config").path,
      "CLAUDE_AGENT_SDK_CLIENT_APP": "AgentOS/1.0", "DISABLE_AUTOUPDATER": "1",
      "AGENTOS_CLAUDE_BIN": claude.path,
    ]
    env.merge(environment) { _, new in new }
    p.environment = env
    p.standardInput = stdin
    p.standardOutput = stdout
    p.standardError = stderr
    stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
      let data = h.availableData
      if data.isEmpty {
        h.readabilityHandler = nil
        return
      }
      Task { @MainActor in
        guard let self, self.generation == generation else { return }
        self.receive(data)
      }
    }
    // SDK diagnostics are not persisted: they may contain model requests or provider details.
    stderr.fileHandleForReading.readabilityHandler = { h in
      if h.availableData.isEmpty { h.readabilityHandler = nil }
    }
    p.terminationHandler = { [weak self] p in
      let status = p.terminationStatus
      Task { @MainActor in
        guard let self, self.generation == generation else { return }
        self.fail(HostError("unavailable", "Agent 引擎退出（\(status)）"))
        self.process = nil
        self.input = nil
      }
    }
    try p.run()
    process = p
    input = stdin.fileHandleForWriting
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK)
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
  }
  func stop() {
    generation = UUID()
    if process?.isRunning == true { process?.terminate() }
    process = nil
    input = nil
    buffer = Data()
    outgoing = []
    outgoingBytes = 0
    writing = false
    hostRequests = 0
    fail(HostError("cancelled", "引擎已停止"))
  }
  func request(_ method: String, _ args: Value) async throws -> Value {
    guard running else { throw HostError("unavailable", "Agent 引擎未启动") }
    guard pending.count < 16 else { throw HostError("rate_limited", "Too many engine requests") }
    next += 1
    let id = next
    return try await withCheckedThrowingContinuation { c in
      pending[id] = c
      send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": args])
    }
  }
  func notify(_ method: String, _ args: Value) {
    send(["jsonrpc": "2.0", "method": .string(method), "params": args])
  }
  private func send(_ value: Value) {
    do {
      guard running, input != nil else { throw HostError("unavailable", "Engine disconnected") }
      let data = try value.encoded() + Data([10])
      guard outgoingBytes + data.count <= 8_000_000 else {
        throw HostError("too_large", "Engine output queue exceeded limit")
      }
      outgoing.append(data)
      outgoingBytes += data.count
      guard !writing else { return }
      writing = true
      let current = generation
      Task { await drain(current) }
    } catch {
      fail(error)
      stop()
    }
  }
  private func drain(_ current: UUID) async {
    defer { if generation == current { writing = false } }
    guard let handle = input else { return }
    let fd = handle.fileDescriptor
    do {
      while generation == current, !outgoing.isEmpty {
        let bytes = outgoing.removeFirst()
        let deadline = Date().addingTimeInterval(10)
        var offset = 0
        while offset < bytes.count {
          guard generation == current, running else { return }
          let count = bytes.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
          }
          if count > 0 {
            offset += count
            outgoingBytes -= count
            continue
          }
          if count < 0, errno == EINTR { continue }
          if count < 0, errno == EAGAIN || errno == EWOULDBLOCK, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
            continue
          }
          throw HostError("unavailable", "Agent 引擎停止读取请求")
        }
      }
    } catch {
      if generation == current {
        fail(error)
        stop()
      }
    }
  }
  private func receive(_ data: Data) {
    buffer.append(data)
    guard buffer.count <= 8_000_000 else {
      stop()
      return
    }
    while let n = buffer.firstIndex(of: 10) {
      let line = buffer[..<n]
      buffer.removeSubrange(...n)
      guard let value = try? Value.parse(String(decoding: line, as: UTF8.self)) else { continue }
      handle(value)
    }
  }
  private func handle(_ value: Value) {
    if let method = value["method"]?.string {
      let args = value["params"] ?? [:]
      guard let id = value["id"] else {
        onUpdate?(args)
        return
      }
      guard hostRequests < 32 else {
        stop()
        return
      }
      hostRequests += 1
      let current = generation
      Task {
        defer { if generation == current { hostRequests -= 1 } }
        do {
          guard let onRequest else { throw HostError("unavailable", "Host disconnected") }
          let result = try await onRequest(method, args)
          guard generation == current else { return }
          send(["jsonrpc": "2.0", "id": id, "result": result])
        } catch {
          guard generation == current else { return }
          let diagnostic = (error as? HostError)?.details ?? .null
          send([
            "jsonrpc": "2.0", "id": id,
            "error": [
              "code": -32000, "message": .string(error.localizedDescription), "data": diagnostic,
            ],
          ])
        }
      }
      return
    }
    guard let id = value["id"]?.int, let c = pending.removeValue(forKey: id) else { return }
    if let error = value["error"] {
      c.resume(throwing: HostError("agent_error", error["message"]?.string ?? "Agent failed"))
    } else {
      c.resume(returning: value["result"] ?? .null)
    }
  }
  private func fail(_ error: Error) {
    let all = pending
    pending = [:]
    for c in all.values { c.resume(throwing: error) }
  }
}
