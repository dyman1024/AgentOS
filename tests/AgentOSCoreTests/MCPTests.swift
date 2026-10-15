import Foundation
import Testing

@testable import AgentOSCore

@Test func mcpCorrelatesResponsesAndRejectsReverseCapabilities() throws {
  let json = Data("{\"jsonrpc\":\"2.0\",\"id\":\"one\",\"result\":{\"ok\":true}}".utf8)
  #expect(try MCPClient.response(json, type: "application/json", id: "one")["ok"] == true)
  let stream = Data(
    "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\r\n\r\nevent: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"one\",\"result\":{\"ok\":true}}\r\n\r\n"
      .utf8)
  #expect(try MCPClient.response(stream, type: "text/event-stream", id: "one")["ok"] == true)
  #expect(throws: HostError.self) {
    try MCPClient.response(json, type: "application/json", id: "different")
  }
  let attack = Data(
    "data: {\"jsonrpc\":\"2.0\",\"id\":\"server-request\",\"method\":\"sampling/createMessage\"}\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"one\",\"result\":{}}\n\n"
      .utf8)
  #expect(throws: HostError.self) {
    try MCPClient.response(attack, type: "text/event-stream", id: "one")
  }
}

actor MCPFixture {
  var methods: [String] = []
  func send(_ request: Value, headers: [String: String]) throws -> HTTPResult {
    let method = request["method"]!.string!
    methods.append(method)
    if method != "initialize" { #expect(headers["Mcp-Session-Id"] == "session-123") }
    if method == "notifications/initialized" {
      return HTTPResult(status: 202, headers: [:], body: Data())
    }
    let result: Value
    if method == "initialize" {
      result = [
        "protocolVersion": "2025-06-18", "capabilities": ["tools": [:]],
        "serverInfo": ["name": "fixture", "version": "1"],
      ]
    } else if method == "tools/list" {
      result = ["tools": [["name": "echo", "inputSchema": ["type": "object"]]]]
    } else {
      result = ["content": [["type": "text", "text": "fixture result"]]]
    }
    let body: Value = ["jsonrpc": "2.0", "id": request["id"]!, "result": result]
    return HTTPResult(
      status: 200, headers: ["content-type": "application/json", "mcp-session-id": "session-123"],
      body: try body.encoded())
  }
}
@Test func mcpInitializesSessionThenDiscoversAndCalls() async throws {
  let fixture = MCPFixture()
  let client = MCPClient { request, headers in try await fixture.send(request, headers: headers) }
  #expect(try await client.tools().count == 1)
  #expect(try await client.call("echo", args: [:])["content"]?.array?.count == 1)
  #expect(
    await fixture.methods == [
      "initialize", "notifications/initialized", "tools/list", "tools/call",
    ])
}
