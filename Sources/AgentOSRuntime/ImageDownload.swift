import AgentOSCore
import Darwin
import Foundation

public enum ImageDownload {
  /// Host-initiated image provisioning only; applications have no access to this downloader.
  public static func artifact(_ artifact: WorkbenchImage.Artifact, to file: URL) async throws {
    let destination = try await HTTPClient.resolve(artifact.url)
    try await Task.detached {
      let process = Process()
      let status = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
      process.arguments = [
        "--disable", "--silent", "--fail", "--proto", "=https", "--noproxy", "*", "--resolve",
        "\(destination.host):\(destination.port):\(destination.address)", "--max-time", "1800",
        "--connect-timeout", "15",
        "--max-filesize", String(artifact.bytes), "--max-redirs", "0", "--output", file.path,
        "--write-out", "%{http_code}", "--url", destination.url.absoluteString,
      ]
      process.environment = ["PATH": "/usr/bin:/bin"]
      process.standardOutput = status
      process.standardError = FileHandle.nullDevice
      try process.run()
      // macOS curl versions that only enforce Content-Length still get an on-disk bound.
      do {
        while process.isRunning {
          if Task.isCancelled { throw CancellationError() }
          let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
          guard size <= artifact.bytes else {
            throw HostError("too_large", "Image download exceeded signed size")
          }
          try await Task.sleep(for: .milliseconds(50))
        }
        process.waitUntilExit()
        let code = String(
          decoding: status.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0, code == "200" else {
          throw HostError("network_error", "Image download failed or redirected")
        }
        try artifact.verify(file)
      } catch {
        if process.isRunning {
          kill(process.processIdentifier, SIGKILL)
          process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: file)
        throw error
      }
    }.value
  }
}
