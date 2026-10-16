import AgentOSCore
import Darwin
import Foundation

public enum NativeSandbox {
  static func literal(_ value: String) throws -> String {
    guard !value.unicodeScalars.contains(where: { $0.value < 32 }) else {
      throw HostError("invalid_args", "Invalid sandbox path")
    }
    return "\""
      + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
        of: "\"", with: "\\\"") + "\""
  }
  static func canonical(_ path: URL) -> String {
    guard let pointer = realpath(path.path, nil) else { return path.standardizedFileURL.path }
    defer { free(pointer) }
    return String(cString: pointer)
  }
  public static func profile(read: [URL], write: [URL], compiler: Bool = false) throws -> String {
    var rules = """
      (version 1)
      (deny default)
      (allow process-exec)
      (allow signal (target self))
      (allow sysctl-read)
      (allow file-read-metadata)
      (allow file-read-data (literal "/"))
      (allow file-read* (subpath "/System") (subpath "/usr/lib") (subpath "/usr/share") (subpath "/Library/Apple") (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random") (subpath "/dev/fd"))
      (allow file-write* (literal "/dev/null") (subpath "/dev/fd"))
      (allow mach-lookup (global-name "com.apple.windowserver.active") (global-name "com.apple.cfprefsd.daemon") (global-name "com.apple.cfprefsd.agent") (global-name "com.apple.fonts") (global-name "com.apple.FontObjectsServer"))
      """
    for path in read + write {
      rules += "\n(allow file-read* (subpath \(try literal(canonical(path)))))"
    }
    for path in write { rules += "\n(allow file-write* (subpath \(try literal(canonical(path)))))" }
    if compiler {
      rules +=
        "\n(allow file-read-data (literal \"/\"))\n(allow process-fork)\n(allow file-read* (subpath \"/usr/bin\") (subpath \"/bin\") (subpath \"/Library/Developer\") (subpath \"/private/var/db/xcode_select_link\"))"
    }
    return rules
  }
  public static func build(source: URL, output: URL) async throws -> URL {
    let sdkFile = Bundle.module.url(forResource: "native-sdk", withExtension: "txt")!
    guard
      let paths = FileManager.default.enumerator(
        at: source.appendingPathComponent("Sources"),
        includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])
    else { throw HostError("invalid_package", "Native app requires Sources/*.swift") }
    var sources: [String] = []
    while let path = paths.nextObject() as? URL {
      guard try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
        throw HostError("invalid_package", "Native source cannot contain links")
      }
      if path.pathExtension == "swift" { sources.append(path.path) }
    }
    guard !sources.isEmpty, sources.count <= 100 else {
      throw HostError("invalid_package", "Native source limit is 1–100 Swift files")
    }
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let sdk = output.appendingPathComponent("AgentOSNative.swift")
    try FileManager.default.copyItem(at: sdkFile, to: sdk)
    let developer = try await command("/usr/bin/xcode-select", ["-p"], timeout: 10)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let compiler = try await command("/usr/bin/xcrun", ["--find", "swiftc"], timeout: 10)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let platformSDK = try await command(
      "/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"], timeout: 10
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let bundle = output.appendingPathComponent("Generated.app")
    let contents = bundle.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(
      at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let manifest = try Value.parse(
      String(contentsOf: source.appendingPathComponent("manifest.json"), encoding: .utf8))
    let id = try manifest.requiredString("id")
    guard UUID(uuidString: id) != nil else {
      throw HostError("invalid_package", "Native bundle ID requires assigned UUID")
    }
    let info: [String: Any] = [
      "CFBundleIdentifier": "dev.agentos.generated." + id,
      "CFBundleName": manifest["title"]?.string ?? "AgentOS Application",
      "CFBundleExecutable": "AgentOSNative", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
      "NSHighResolutionCapable": true,
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
      to: contents.appendingPathComponent("Info.plist"))
    let resources = source.appendingPathComponent("Resources")
    if FileManager.default.fileExists(atPath: resources.path) {
      try FileManager.default.copyItem(
        at: resources, to: contents.appendingPathComponent("Resources"))
    }
    let executable = contents.appendingPathComponent("MacOS/AgentOSNative")
    let rules = try profile(
      read: [
        source, URL(fileURLWithPath: developer),
        URL(fileURLWithPath: developer).deletingLastPathComponent().appendingPathComponent(
          "SharedFrameworks"),
      ], write: [output], compiler: true)
    try Data(rules.utf8).write(to: output.appendingPathComponent("compiler.sb"))
    _ = try await command(
      "/usr/bin/sandbox-exec",
      [
        "-p", rules, compiler, "-sdk", platformSDK, "-swift-version", "5", "-parse-as-library",
        "-module-cache-path", output.appendingPathComponent("cache").path,
      ] + sources.sorted() + [sdk.path, "-o", executable.path],
      environment: ["PATH": "/usr/bin:/bin", "HOME": output.path, "TMPDIR": output.path],
      timeout: 120)
    _ = try await command(
      "/usr/bin/codesign", ["--force", "--sign", "-", bundle.path], timeout: 30)
    return executable
  }
  static func command(
    _ executable: String, _ arguments: [String],
    environment: [String: String] = ["PATH": "/usr/bin:/bin"], timeout: Double
  ) async throws -> String {
    try await Task.detached {
      let process = Process()
      let out = Pipe()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      process.environment = environment
      process.standardOutput = out
      process.standardError = out
      try process.run()
      let fd = out.fileHandleForReading.fileDescriptor
      _ = fcntl(fd, F_SETFL, O_NONBLOCK)
      let deadline = Date().addingTimeInterval(timeout)
      var bytes = Data()
      var buffer = [UInt8](repeating: 0, count: 65536)
      while true {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 { bytes.append(contentsOf: buffer.prefix(count)) }
        if bytes.count > 2_000_000 || Date() >= deadline {
          process.terminate()
          kill(process.processIdentifier, SIGKILL)
          process.waitUntilExit()
          throw HostError("build_failed", "Compiler exceeded time or output limit")
        }
        if !process.isRunning && count <= 0 { break }
        usleep(10000)
      }
      process.waitUntilExit()
      let text = String(decoding: bytes, as: UTF8.self)
      guard process.terminationStatus == 0 else {
        throw HostError(
          "build_failed",
          "Process exited \(process.terminationStatus) (\(process.terminationReason.rawValue)): "
            + text)
      }
      return text
    }.value
  }
}
