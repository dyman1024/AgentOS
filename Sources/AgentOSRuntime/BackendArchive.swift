import AgentOSCore
import Foundation

extension WorkbenchVM {
  /// Binary archives are copied into the isolated guest; the host never extracts image layers.
  func copyArchive(_ source: URL, to path: String) async throws {
    let values = try source.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let count = values.fileSize, count > 0, count <= 200_000_000
    else { throw HostError("too_large", "OCI image archive must be a regular file up to 200 MB") }
    let handle = try FileHandle(forReadingFrom: source)
    defer { try? handle.close() }
    var offset = 0
    while offset < count {
      let chunk = try handle.read(upToCount: min(512_000, count - offset)) ?? Data()
      guard !chunk.isEmpty else { throw HostError("conflict", "Archive changed while copying") }
      _ = try await execute(
        "fs.chunk",
        args: [
          "path": .string(path), "offset": .number(Double(offset)),
          "base64": .string(chunk.base64EncodedString()),
        ])
      offset += chunk.count
    }
  }
}
