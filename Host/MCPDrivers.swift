import AgentOSCore
import Foundation
import Observation

struct MCPDriver: Codable, Identifiable {
  let id: String, name: String, endpoint: String, tools: [Value]
}
@MainActor @Observable final class MCPDrivers {
  let kernel: Kernel, settings: ModelSettings, config: URL
  private(set) var drivers: [MCPDriver] = []
  private(set) var status = "未连接 MCP 驱动"
  var confirm: ((String, Value) async -> Bool)?
  init(kernel: Kernel, settings: ModelSettings, root: URL) {
    self.kernel = kernel
    self.settings = settings
    config = root.appendingPathComponent("system/mcp-drivers.json")
    if let bytes = try? Data(contentsOf: config) {
      drivers = (try? JSONDecoder().decode([MCPDriver].self, from: bytes)) ?? []
    }
  }
  private func persist() throws {
    try JSONEncoder().encode(drivers).write(to: config, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
  }
  private func client(
    endpoint: String, token: String?, authorize: @escaping @Sendable () async throws -> Void
  ) -> MCPClient {
    MCPClient { request, headers in
      let target = try await HTTPClient.resolve(endpoint)
      try await authorize()
      var headers = headers
      if let token, !token.isEmpty { headers["Authorization"] = "Bearer " + token }
      return try await HTTPClient.send(
        target, method: "POST", headers: headers, body: request.encoded())
    }
  }
  func connect(name: String, endpoint: String, token: String) async throws {
    guard Kernel.validName(name), !drivers.contains(where: { $0.name == name }), drivers.count < 20
    else { throw HostError("invalid_args", "驱动名称必须唯一，使用小写字母、数字和连字符") }
    _ = try HTTPClient.validateURL(endpoint)
    status = "正在读取 MCP 工具目录"
    let id = UUID().uuidString
    let client = client(endpoint: endpoint, token: token, authorize: {})
    let tools = try await client.tools()
    if !token.isEmpty { try settings.saveCredential("mcp:" + id, value: token) }
    drivers.append(MCPDriver(id: id, name: name, endpoint: endpoint, tools: tools))
    try persist()
    status = "已连接 \(name)，\(tools.count) 个工具；工具调用按不可逆操作审批"
  }
  func remove(_ id: String) throws {
    drivers.removeAll { $0.id == id }
    try persist()
    try settings.removeCredential("mcp:" + id)
  }
  func describe() -> Value {
    .array(
      drivers.flatMap { driver in
        driver.tools.map { tool in
          [
            "name": .string("ext." + driver.name + "." + (tool["name"]?.string ?? "")),
            "description": tool["description"] ?? "", "input": tool["inputSchema"] ?? [:],
            "output": tool["outputSchema"] ?? [:], "effectCeiling": "irreversible",
            "trust": "untrusted",
          ] as Value
        }
      })
  }
  private func ensureConnected(_ id: String) throws {
    guard drivers.contains(where: { $0.id == id }) else { throw HostError("denied", "驱动已断开") }
  }
  func call(_ name: String, args: Value, context: RequestContext) async throws -> Value {
    try await kernel.authorize(context, capability: "call", scope: name)
    if name == "ext.list" { return describe() }
    let parts = name.split(separator: ".").map(String.init)
    guard parts.count == 3, let driver = drivers.first(where: { $0.name == parts[1] }),
      let tool = driver.tools.first(where: { $0["name"]?.string == parts[2] })
    else { throw HostError("not_found", "MCP 工具未连接") }
    try await kernel.consumeQuota(name, limit: 100, capability: "call", context: context)
    try Schema.validate(args, against: tool["inputSchema"] ?? [:])
    let ticket = try await kernel.prepareSink(
      action: name, args: args, effect: .irreversible, capability: "call", scope: name,
      context: context)
    if ticket.state == "pending" {
      guard try await kernel.initiator(of: context) != .service("cli") else {
        throw HostError(
          "needs_confirmation", "MCP 调用需要宿主确认", details: ["operationID": .string(ticket.id)])
      }
      let allowed = await confirm?(ticket.reason ?? name, args) ?? false
      try await kernel.approveSink(ticket.id, allow: allowed)
      guard allowed else { throw HostError("denied", "MCP 调用未获批准") }
    }
    _ = try await kernel.claimSink(ticket.id, context: context)
    do {
      let client = client(endpoint: driver.endpoint, token: settings.credential("mcp:" + driver.id))
      { [weak self, kernel] in
        guard let self else { throw HostError("unavailable", "Host stopped") }
        try await self.ensureConnected(driver.id)
        try await kernel.authorize(context, capability: "call", scope: name)
      }
      let current = try await client.tools()
      guard
        current.first(where: { $0["name"] == tool["name"] })?["inputSchema"] == tool["inputSchema"],
        current.first(where: { $0["name"] == tool["name"] })?["outputSchema"]
          == tool["outputSchema"]
      else { throw HostError("conflict", "MCP 工具契约已变化，请重新连接驱动") }
      guard drivers.contains(where: { $0.id == driver.id }) else {
        throw HostError("denied", "驱动已断开")
      }
      let result = try await client.call(parts[2], args: args)
      try ensureConnected(driver.id)
      try await kernel.propagate(
        Labels(taint: ["mcp:" + driver.name], isPrivate: true), to: context)
      try await kernel.finishSink(ticket.id, state: "done", result: result)
      try await kernel.validateContext(context)
      return result
    } catch {
      try? await kernel.finishSink(
        ticket.id, state: "unknown", result: ["message": .string(error.localizedDescription)])
      throw error
    }
  }
}
