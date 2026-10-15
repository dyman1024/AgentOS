import AgentOSCore
import Darwin
import Foundation
import Network
import Security

final class HostLease {
  var fd: Int32
  init(root: URL) throws {
    let folder = root.appendingPathComponent("system")
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    fd = Darwin.open(folder.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      if fd >= 0 { Darwin.close(fd) }
      throw HostError("conflict", "另一个 AgentOS 宿主正在使用此数据目录")
    }
  }
  func release() {
    if fd >= 0 {
      flock(fd, LOCK_UN)
      Darwin.close(fd)
      fd = -1
    }
  }
  deinit { if fd >= 0 { Darwin.close(fd) } }
}
@MainActor final class CLIService {
  func stop() {
    listener?.cancel()
    listener = nil
    try? FileManager.default.removeItem(at: socket)
  }
  private var listener: NWListener?
  private let token: String
  private let socket: URL
  private let handler: (String, Value, Bool) async throws -> Value
  init(root: URL, handler: @escaping (String, Value, Bool) async throws -> Value) throws {
    self.handler = handler
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw HostError("unavailable", "Cannot create CLI session")
    }
    token = Data(bytes).base64EncodedString()
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "aos-" + String(Kernel.digest(Data(root.path.utf8)).prefix(16)))
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    socket = directory.appendingPathComponent("host.sock")
    try? FileManager.default.removeItem(at: socket)
    let endpoint: Value = ["socket": .string(socket.path), "token": .string(token)]
    let file = root.appendingPathComponent("system/aos-session.json")
    try endpoint.encoded().write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .unix(path: socket.path)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.accept(connection) }
    }
    listener.stateUpdateHandler = { [socket] state in
      if case .ready = state {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: socket.path)
      }
    }
    listener.start(queue: .main)
  }
  private func accept(_ connection: NWConnection) {
    connection.start(queue: .main)
    read(connection, buffer: Data())
  }
  private func read(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] data, _, complete, error in
      Task { @MainActor in
        guard let self else {
          connection.cancel()
          return
        }
        var buffer = buffer
        buffer.append(data ?? Data())
        guard buffer.count <= 2_000_000 else {
          connection.cancel()
          return
        }
        if let end = buffer.firstIndex(of: 10) {
          let response: Value
          do {
            let request = try Value.parse(String(decoding: buffer[..<end], as: UTF8.self))
            guard request["token"]?.string == self.token else {
              throw HostError("denied", "CLI session is invalid; reopen the host")
            }
            let result = try await self.handler(
              request.requiredString("method"), request["args"] ?? [:],
              request["dryRun"]?.bool ?? false)
            response = ["result": result]
          } catch {
            let e = (error as? HostError) ?? HostError("failed", error.localizedDescription)
            response = ["error": (try? Value.from(e)) ?? .null]
          }
          var data = (try? response.encoded()) ?? Data()
          data.append(10)
          connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        } else if complete || error != nil {
          connection.cancel()
        } else {
          self.read(connection, buffer: buffer)
        }
      }
    }
  }
}
