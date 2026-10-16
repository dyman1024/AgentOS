import AgentOSCore
import Foundation

extension AppModel {
  func requireLocalValidationHost() throws {
    guard ProcessInfo.processInfo.environment["AGENTOS_LOCAL_CHECKS"] == "1",
      ProcessInfo.processInfo.environment["AGENTOS_DATA_ROOT"] != nil,
      root.lastPathComponent.hasPrefix("agentos-local-check-"), !busy
    else {
      throw HostError("denied", "Local checks require an isolated validation host")
    }
  }
  func localValidationState() throws -> Value {
    try requireLocalValidationHost()
    return ["safeMode": .bool(safeMode), "customShell": shellAppID.map(Value.string) ?? .null]
  }
  /// Deterministic host checks are confined to an explicitly launched disposable data root.
  func localHostChecks() async throws -> Value {
    try requireLocalValidationHost()
    let user = RequestContext(.user)
    var passed: [Value] = []
    func check(_ value: Bool, _ name: String) throws {
      guard value else { throw HostError("test_failed", name) }
      passed.append(.string(name))
    }
    let folderURL = root.appendingPathComponent("media-fixture")
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    // Ten seconds of silent PCM audio; no downloaded media or account is involved.
    var wave = Data()
    func ascii(_ text: String) { wave.append(Data(text.utf8)) }
    func u16(_ value: UInt16) {
      var v = value.littleEndian
      withUnsafeBytes(of: &v) { wave.append(contentsOf: $0) }
    }
    func u32(_ value: UInt32) {
      var v = value.littleEndian
      withUnsafeBytes(of: &v) { wave.append(contentsOf: $0) }
    }
    let size: UInt32 = 16000 * 2 * 10
    ascii("RIFF")
    u32(size + 36)
    ascii("WAVEfmt ")
    u32(16)
    u16(1)
    u16(1)
    u32(16000)
    u32(32000)
    u16(2)
    u16(16)
    ascii("data")
    u32(size)
    wave.append(Data(repeating: 0, count: Int(size)))
    try wave.write(to: folderURL.appendingPathComponent("silence.wav"))
    let folder = try await kernel.addFolder(folderURL).requiredString("id")
    let args: Value = ["folder": .string(folder), "path": "silence.wav"]
    defer { services.media.close() }
    let scan = try await services.media.scan(["folder": .string(folder)], context: user)
    try check(scan["count"] == 1, "media scan indexes a local WAV")
    let metadata = try await services.media.metadata(args, context: user)
    try check(
      abs((metadata["duration"]?.number ?? 0) - 10) < 0.1,
      "AVFoundation decodes duration through authorized byte ranges")
    _ = try await services.media.play(args, context: user)
    var status: Value = [:]
    for _ in 0..<30 {
      try await Task.sleep(for: .milliseconds(100))
      status = try await services.media.control("media.status", args: [:], context: user)
      if (status["position"]?.number ?? 0) > 0.1 { break }
    }
    try check((status["position"]?.number ?? 0) > 0.1, "real AVPlayer playback advances")
    _ = try await services.media.control("media.pause", args: [:], context: user)
    status = try await services.media.control("media.seek", args: ["position": 3], context: user)
    try check(
      abs((status["position"]?.number ?? 0) - 3) < 0.2, "pause and seek update playback position")
    _ = try await services.media.control("media.resume", args: [:], context: user)
    _ = try await services.media.control("media.stop", args: [:], context: user)
    let indexed = try await kernel.query("media", context: user)
    try check(indexed.first?.fields["progress"]?.number != nil, "playback progress is persisted")
    try await kernel.revokeFolder(folder)
    do {
      _ = try await services.media.metadata(args, context: user)
      throw HostError("test_failed", "Revoked folder remained readable")
    } catch let error as HostError {
      try check(error.code == "denied", "revoked media folder rejects subsequent reads")
    }
    return ["pass": true, "checks": .array(passed), "modelCalls": 0, "externalAccounts": false]
  }
}
