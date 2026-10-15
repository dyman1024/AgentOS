import Darwin
import Foundation

struct CLIError: Error {
  let code: Int32
  let message: String
}
func request(_ method: String, _ args: [String: Any], dry: Bool = false) throws -> Any {
  let root =
    ProcessInfo.processInfo.environment["AGENTOS_DATA_ROOT"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("AgentOS-Rebuild")
  guard let data = try? Data(contentsOf: root.appendingPathComponent("system/aos-session.json")),
    let config = try JSONSerialization.jsonObject(with: data) as? [String: String],
    let path = config["socket"], let token = config["token"]
  else { throw CLIError(code: 1, message: "AgentOS is not running. Open the application first.") }
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { throw CLIError(code: 1, message: "Cannot create socket") }
  defer { close(fd) }
  var timeout = timeval(tv_sec: 180, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  var noSignal: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8) + [0]
  guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
    throw CLIError(code: 1, message: "Socket path is too long")
  }
  withUnsafeMutableBytes(of: &address.sun_path) { dest in dest.copyBytes(from: bytes) }
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  let connected = withUnsafePointer(to: &address) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard connected == 0 else { throw CLIError(code: 1, message: "Cannot connect to AgentOS") }
  var payload = try JSONSerialization.data(
    withJSONObject: ["token": token, "method": method, "args": args, "dryRun": dry],
    options: [.sortedKeys])
  payload.append(10)
  try payload.withUnsafeBytes { raw in
    var sent = 0
    while sent < raw.count {
      let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
      guard n > 0 else { throw CLIError(code: 1, message: "Host disconnected") }
      sent += n
    }
  }
  var result = Data()
  var chunk = [UInt8](repeating: 0, count: 65536)
  while !result.contains(10) {
    let n = read(fd, &chunk, chunk.count)
    guard n > 0, result.count < 8_000_000 else {
      throw CLIError(code: 1, message: "Host response timed out or exceeded the limit")
    }
    result.append(contentsOf: chunk.prefix(n))
  }
  guard let response = try JSONSerialization.jsonObject(with: result) as? [String: Any] else {
    throw CLIError(code: 1, message: "Invalid response")
  }
  if let error = response["error"] as? [String: Any] {
    let code = error["code"] as? String
    throw CLIError(
      code: code == "denied"
        ? 3 : code == "needs_confirmation" ? 4 : code == "invalid_args" ? 2 : 1,
      message: try String(
        decoding: JSONSerialization.data(withJSONObject: error, options: [.sortedKeys]),
        as: UTF8.self))
  }
  return response["result"] ?? NSNull()
}
func printJSON(_ value: Any) throws {
  print(
    String(
      decoding: try JSONSerialization.data(
        withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]),
      as: UTF8.self))
}
func camel(_ value: String) -> String {
  let parts = value.split(separator: "-")
  return (parts.first.map(String.init) ?? "")
    + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
}
do {
  var words = Array(CommandLine.arguments.dropFirst())
  var dry = false
  if let i = words.firstIndex(of: "--dry-run") {
    words.remove(at: i)
    dry = true
  }
  words.removeAll { $0 == "--json" }
  if words.isEmpty || words == ["--help"] {
    print(
      "aos apps list | aos call namespace.tool '{\"arg\":\"value\"}' | aos data query notes --text word | aos events tail 'note.*' | aos <app> <tool> --parameter value [--json] [--dry-run]"
    )
    exit(0)
  }
  if words.first == "call" {
    guard words.count >= 2 else { throw CLIError(code: 2, message: "Missing tool name") }
    let args =
      words.count > 2
      ? try JSONSerialization.jsonObject(with: Data(words[2].utf8)) as? [String: Any] ?? [:] : [:]
    try printJSON(request("apps.call", ["tool": words[1], "args": args], dry: dry))
    exit(0)
  }
  if words.first == "events", words.dropFirst().first == "tail" {
    var cursor = 0
    repeat {
      let value =
        try request("events.list", ["after": cursor, "pattern": words.count > 2 ? words[2] : "*"])
        as? [[String: Any]] ?? []
      for entry in value {
        cursor = entry["cursor"] as? Int ?? cursor
        try printJSON(entry)
      }
      fflush(stdout)
      Thread.sleep(forTimeInterval: 1)
    } while true
  }
  guard words.count >= 2 else { throw CLIError(code: 2, message: "Expected a domain and command") }
  let domain = words.removeFirst()
  let command = camel(words.removeFirst())
  let system = [
    "apps", "data", "events", "activity", "automation", "system", "workspace", "net", "web",
    "files", "mail", "calendar", "contacts", "media", "ai", "vm", "clipboard",
  ]
  var properties: [String: Any] = [:]
  if !system.contains(domain),
    let description = try request("apps.describe", ["tool": domain + "." + command])
      as? [String: Any], let input = description["input"] as? [String: Any]
  {
    properties = input["properties"] as? [String: Any] ?? [:]
  }
  var args: [String: Any] = [:]
  if domain == "data", let first = words.first, !first.hasPrefix("--") {
    args["collection"] = words.removeFirst()
  }
  while !words.isEmpty {
    let flag = words.removeFirst()
    guard flag.hasPrefix("--"), !words.isEmpty else {
      throw CLIError(code: 2, message: "Expected --parameter value")
    }
    let text = words.removeFirst()
    var value: Any =
      (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]))
      ?? text
    let raw = String(flag.dropFirst(2))
    let normalized = raw.replacingOccurrences(of: "-", with: "").lowercased()
    let key =
      properties.keys.first { $0.lowercased() == normalized }
      ?? (raw == "effect-id" ? "effectID" : camel(raw))
    if let schema = properties[key] as? [String: Any], schema["type"] as? String == "string" {
      value = text
    }
    args[key] = value
  }
  if domain == "system", command == "call" {
    guard let method = args["method"] as? String else {
      throw CLIError(code: 2, message: "system call requires --method and optional --args JSON")
    }
    try printJSON(request(method, args["args"] as? [String: Any] ?? [:], dry: dry))
  } else if system.contains(domain) {
    try printJSON(request(domain + "." + command, args, dry: dry))
  } else {
    try printJSON(request("apps.call", ["tool": domain + "." + command, "args": args], dry: dry))
  }
} catch let e as CLIError {
  fputs(e.message + "\n", stderr)
  exit(e.code)
} catch {
  fputs(error.localizedDescription + "\n", stderr)
  exit(1)
}
