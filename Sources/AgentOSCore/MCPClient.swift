import Foundation

/// Bounded Streamable HTTP client. It never accepts server-initiated host tools or sampling.
public actor MCPClient {
  public typealias Transport = @Sendable (Value, [String: String]) async throws -> HTTPResult
  private let transport: Transport
  private var session: String?, version = "2025-06-18"
  private var initialized = false
  public init(transport: @escaping Transport) { self.transport = transport }
  public static func response(_ body: Data, type: String, id: String) throws -> Value {
    guard body.count <= 2_000_000 else {
      throw HostError("too_large", "MCP response exceeds limit")
    }
    let text = String(decoding: body, as: UTF8.self)
    var messages: [Value] = []
    if type.lowercased().hasPrefix("text/event-stream") {
      let events = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
      for event in events {
        let data = event.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map {
          String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
        if !data.isEmpty { messages.append(try Value.parse(data)) }
      }
    } else if type.lowercased().hasPrefix("application/json") {
      messages = [try Value.parse(text)]
    } else {
      throw HostError("protocol_error", "Unsupported MCP content type")
    }
    guard !messages.contains(where: { $0["method"] != nil && $0["id"] != nil }) else {
      throw HostError("denied", "MCP server requests for host capabilities are not supported")
    }
    let replies = messages.filter { $0["id"]?.string == id && $0["jsonrpc"] == "2.0" }
    guard replies.count == 1 else {
      throw HostError("protocol_error", "Missing or duplicate MCP response")
    }
    if let error = replies[0]["error"] {
      throw HostError(
        "mcp_error", String((error["message"]?.string ?? "Remote request failed").prefix(2000)))
    }
    guard let result = replies[0]["result"] else {
      throw HostError("protocol_error", "MCP result is missing")
    }
    return result
  }
  private func request(_ method: String, params: Value, notification: Bool = false) async throws
    -> Value
  {
    let id = UUID().uuidString
    var message: [String: Value] = ["jsonrpc": "2.0", "method": .string(method), "params": params]
    if !notification { message["id"] = .string(id) }
    var headers = [
      "Accept": "application/json, text/event-stream", "Content-Type": "application/json",
      "MCP-Protocol-Version": version,
    ]
    if let session { headers["Mcp-Session-Id"] = session }
    let response = try await transport(.object(message), headers)
    guard (200..<300).contains(response.status) else {
      if response.status == 404 {
        initialized = false
        session = nil
      }
      throw HostError(
        "mcp_error", "MCP server returned HTTP \(response.status); operation is not retried")
    }
    if method == "initialize", let value = response.headers["mcp-session-id"] {
      guard value.utf8.count <= 4096,
        value.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) })
      else { throw HostError("protocol_error", "Invalid MCP session ID") }
      session = value
    }
    if notification { return [:] }
    return try Self.response(response.body, type: response.headers["content-type"] ?? "", id: id)
  }
  private func initialize() async throws {
    guard !initialized else { return }
    let result = try await request(
      "initialize",
      params: [
        "protocolVersion": .string(version), "capabilities": [:],
        "clientInfo": ["name": "AgentOS", "version": "1.0.0"],
      ])
    guard let negotiated = result["protocolVersion"]?.string,
      ["2025-03-26", "2025-06-18"].contains(negotiated)
    else { throw HostError("protocol_error", "MCP server negotiated an unsupported protocol") }
    version = negotiated
    _ = try await request("notifications/initialized", params: [:], notification: true)
    initialized = true
  }
  public func tools() async throws -> [Value] {
    try await initialize()
    var result: [Value] = []
    var cursor: String?
    for _ in 0..<20 {
      let page = try await request(
        "tools/list", params: cursor.map { ["cursor": .string($0)] } ?? [:])
      guard let items = page["tools"]?.array, items.count + result.count <= 1000 else {
        throw HostError("protocol_error", "MCP tool list exceeds limit")
      }
      for item in items {
        guard let name = item["name"]?.string,
          name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
          !result.contains(where: { $0["name"] == item["name"] }), let schema = item["inputSchema"]
        else { throw HostError("protocol_error", "Invalid or duplicate MCP tool") }
        try Schema.lint(schema)
        result.append(item)
      }
      cursor = page["nextCursor"]?.string
      if cursor == nil { return result }
    }
    throw HostError("too_large", "MCP pagination exceeds limit")
  }
  public func call(_ name: String, args: Value) async throws -> Value {
    try await initialize()
    return try await request("tools/call", params: ["name": .string(name), "arguments": args])
  }
}
