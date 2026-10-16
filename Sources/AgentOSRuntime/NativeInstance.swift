import AgentOSCore
import Darwin
import Foundation

@MainActor public final class NativeInstance: CoreHost {
  public let app: InstalledApp, instanceID: String
  public var context: RequestContext?
  public private(set) var lastUsed = Date(), invalidated = false
  public var onRequest: ((String, Value, RequestContext) async throws -> Value)?
  public var onSubscription: ((String) async throws -> Void)?
  private let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
  private var buffer = Data(), registered = Set<String>()
  private var pending: [String: CheckedContinuation<Value, Error>] = [:]
  private var failure: Error?
  private var diagnostic = ""
  private var writing = false
  private var requests = Set<String>()
  private let executable: URL, storage: URL, isCore: Bool
  public init(app: InstalledApp, executable: URL, storage: URL, isCore: Bool, instanceID: String) {
    self.app = app
    self.executable = executable
    self.storage = storage
    self.isCore = isCore
    self.instanceID = instanceID
  }
  public func ready() async throws {
    try FileManager.default.createDirectory(
      at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let profile = try NativeSandbox.profile(
      read: [executable.deletingLastPathComponent().deletingLastPathComponent()], write: [storage])
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    process.arguments = ["-p", profile, executable.path, isCore ? "--mcp" : "--agentos-ui"]
    process.currentDirectoryURL = storage
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": storage.path, "TMPDIR": storage.path]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let bytes = handle.availableData
      Task { @MainActor in self?.receive(bytes) }
    }
    errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let bytes = handle.availableData
      Task { @MainActor in
        self?.diagnostic = String(
          ((self?.diagnostic ?? "") + String(decoding: bytes, as: UTF8.self)).suffix(4000))
      }
    }
    process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.close() } }
    try process.run()
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK)
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    let deadline = Date().addingTimeInterval(10)
    let expected = Set(try AppInterface(app.interface).tools.map(\.name))
    while isCore && registered != expected {
      if let failure { throw failure }
      guard !invalidated, Date() < deadline else {
        close()
        throw HostError(
          "unavailable",
          "Native core failed to register declared tools (running=\(process.isRunning), invalidated=\(invalidated), registered=\(registered.count), exit=\(process.isRunning ? -999 : process.terminationStatus)): "
            + diagnostic)
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
  private func receive(_ bytes: Data) {
    guard !invalidated else { return }
    guard !bytes.isEmpty, buffer.count + bytes.count <= 2_100_000 else {
      close()
      return
    }
    buffer.append(bytes)
    while let newline = buffer.firstIndex(of: 10) {
      let line = Data(buffer[..<newline])
      buffer.removeSubrange(...newline)
      do {
        let message = try Value.parse(String(decoding: line, as: UTF8.self))
        let id = try message.requiredString("id")
        if let method = message["method"]?.string {
          guard requests.count < 16, id.count <= 128, requests.insert(id).inserted else {
            close()
            return
          }
          Task { [weak self] in
            await self?.request(id, method: method, args: message["args"] ?? [:])
          }
        } else if let continuation = pending.removeValue(forKey: id) {
          if let error = message["error"] {
            continuation.resume(
              throwing: HostError(
                error["code"]?.string ?? "app_error",
                error["message"]?.string ?? "Native tool failed"))
          } else {
            continuation.resume(returning: message["result"] ?? .null)
          }
        }
      } catch {
        failure = error
        close()
        return
      }
    }
  }
  private func request(_ id: String, method: String, args: Value) async {
    defer { requests.remove(id) }
    do {
      guard !invalidated else { return }
      let result: Value
      switch method {
      case "tools.register":
        let name = try args.requiredString("name")
        guard isCore, try AppInterface(app.interface).tools.contains(where: { $0.name == name }),
          registered.insert(name).inserted
        else { throw HostError("denied", "Undeclared or duplicate native tool") }
        result = [:]
      case "events.subscribe":
        guard isCore, let onSubscription else {
          throw HostError("denied", "Only native core can subscribe")
        }
        try await onSubscription(args.requiredString("pattern"))
        result = [:]
      default:
        guard let context, let onRequest else {
          throw HostError("denied", "Native core has no active host invocation")
        }
        result = try await onRequest(method, args, context)
      }
      try await write(["id": .string(id), "result": result])
    } catch {
      let error = (error as? HostError) ?? HostError("app_error", error.localizedDescription)
      try? await write([
        "id": .string(id),
        "error": ["code": .string(error.code), "message": .string(error.message)],
      ])
    }
  }
  private func write(_ message: Value) async throws {
    guard !invalidated else { throw HostError("unavailable", "Native process stopped") }
    while writing && !invalidated { try await Task.sleep(for: .milliseconds(1)) }
    guard !invalidated else { throw HostError("unavailable", "Native process stopped") }
    writing = true
    defer { writing = false }
    let bytes = try message.encoded() + Data([10])
    let fd = input.fileHandleForWriting.fileDescriptor
    guard bytes.count <= 2_100_000 else {
      throw HostError("too_large", "Native message exceeds limit")
    }
    try await Task.detached {
      try bytes.withUnsafeBytes { buffer in
        var sent = 0
        let deadline = Date().addingTimeInterval(5)
        while sent < buffer.count {
          let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
          if count > 0 {
            sent += count
            continue
          }
          guard errno == EAGAIN, Date() < deadline else {
            throw HostError("unavailable", "Native process stopped reading")
          }
          usleep(1000)
        }
      }
    }.value
  }
  public func invoke(kind: String, name: String, args: Value) async throws -> Value {
    lastUsed = Date()
    let id = UUID().uuidString
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      Task { [weak self] in
        guard let self else { return }
        do {
          try await write([
            "id": .string(id), "kind": .string(kind), "name": .string(name), "args": args,
          ])
        } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
      }
    }
  }
  public func close() {
    guard !invalidated else { return }
    invalidated = true
    context = nil
    if process.isRunning {
      process.terminate()
      kill(process.processIdentifier, SIGKILL)
    }
    output.fileHandleForReading.readabilityHandler = nil
    errors.fileHandleForReading.readabilityHandler = nil
    for continuation in pending.values {
      continuation.resume(throwing: HostError("unavailable", "Native process stopped"))
    }
    pending.removeAll()
  }
}
