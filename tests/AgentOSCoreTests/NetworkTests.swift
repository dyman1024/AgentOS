import Foundation
import Testing

@testable import AgentOSCore

private actor MockHTTP {
  var calls: [String] = []
  var headers: [[String: String]] = []
  let redirects: Bool
  init(redirects: Bool = true) { self.redirects = redirects }
  func send(_ d: HTTPDestination, _ h: [String: String]) -> HTTPResult {
    calls.append(d.host)
    headers.append(h)
    if redirects && calls.count == 1 {
      return HTTPResult(
        status: 302, headers: ["location": "https://second.example/page"], body: Data())
    }
    return HTTPResult(
      status: 200, headers: ["content-type": "text/plain", "set-cookie": "secret=x"],
      body: Data("content".utf8))
  }
}
private let testResolver: NetworkGateway.Resolver = { input in
  let url = try HTTPClient.validateURL(input)
  return HTTPDestination(url: url, host: url.host!, address: "8.8.8.8", port: 443)
}
@Test func networkRejectsPrivateAddressesAndMalformedHeaders() async throws {
  for ip in [
    "127.0.0.1", "10.0.0.1", "169.254.169.254", "100.64.0.1", "172.31.1.2", "192.168.1.1",
    "198.18.1.1", "203.0.113.1", "224.0.0.1", "999.1.2.3",
  ] { #expect(!HTTPClient.isPublicIPv4(ip)) }
  #expect(HTTPClient.isPublicIPv4("8.8.8.8"))
  for url in [
    "http://example.com", "https://user:pass@example.com", "file:///tmp/test", "https://[::1]",
  ] { #expect(throws: HostError.self) { try HTTPClient.validateURL(url) } }
  #expect(throws: HostError.self) {
    try HTTPClient.validateRequest(
      method: "GET", headers: ["X-Test": "a\r\nAuthorization:b"], body: nil, maximumBytes: 10)
  }
  #expect(throws: HostError.self) {
    try HTTPClient.validateRequest(
      method: "GET", headers: ["Host": "127.0.0.1"], body: nil, maximumBytes: 10)
  }
  await expectCode("denied") { _ = try await HTTPClient.resolve("https://127.0.0.1") }
}
@Test func redirectsRecheckGrantsAndNeverForwardCredentials() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let c = RequestContext(.core("reader"))
  _ = try await k.grant(holder: .core("reader"), capability: "net", scope: "first.example")
  let mock = MockHTTP()
  let gateway = NetworkGateway(
    kernel: k, resolve: testResolver, send: { d, _, h, _, _ in await mock.send(d, h) })
  await expectCode("denied") {
    _ = try await gateway.fetch(["url": "https://first.example"], context: c)
  }
  #expect(await mock.calls == ["first.example"])
  let next = MockHTTP()
  let allowed = NetworkGateway(
    kernel: k, resolve: testResolver, send: { d, _, h, _, _ in await next.send(d, h) })
  let result = try await allowed.fetch(
    ["url": "https://first.example", "headers": ["Authorization": "Bearer test-only"]],
    context: user)
  #expect(await next.headers == [["Authorization": "Bearer test-only"], [:]])
  #expect(result["headers"]?["set-cookie"] == nil)
}
@Test func irreversibleNetworkRequiresConfirmationAndIsSingleExecution() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let id = try await k.startRun(session: "fetch")
  let c = RequestContext(.run(id), runID: id)
  try await k.propagate(Labels(taint: ["web:source"]), to: c)
  let mock = MockHTTP(redirects: false)
  let gateway = NetworkGateway(
    kernel: k, resolve: testResolver, send: { d, _, h, _, _ in await mock.send(d, h) })
  await expectCode("needs_confirmation") {
    _ = try await gateway.fetch(
      ["url": "https://first.example", "method": "POST", "body": "draft"], context: c)
  }
  #expect(await mock.calls.isEmpty)
  _ = try await gateway.fetch(
    ["url": "https://first.example", "method": "POST", "body": "draft"], context: c,
    confirm: { _ in true })
  #expect(await mock.calls.count == 1)
  #expect(try await k.labels(for: c).taint.contains("web:https://first.example"))
}

@Test func fakeIPCompatibilityStillRejectsPrivatePublicDNSAnswers() throws {
  #expect(
    try HTTPClient.publicDNSAnswers([
      "Status": 0,
      "Answer": [["type": 1, "data": "8.8.8.8"], ["type": 5, "data": "alias.example"]],
    ]) == ["8.8.8.8"])
  for address in ["127.0.0.1", "10.0.0.1", "198.18.1.2", "169.254.169.254"] {
    #expect(throws: HostError.self) {
      try HTTPClient.publicDNSAnswers([
        "Status": 0, "Answer": [["type": 1, "data": .string(address)]],
      ])
    }
  }
}
