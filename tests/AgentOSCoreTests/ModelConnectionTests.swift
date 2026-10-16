import Foundation
import Security
import Testing

@testable import AgentOSCore

@Test func keychainSaveReadReplaceAndProviderIsolation() throws {
  let store = CredentialStore(service: "dev.agentos.tests." + UUID().uuidString)
  defer {
    try? store.remove("openrouter")
    try? store.remove("anthropic")
  }
  #expect(try store.read("openrouter") == nil)
  try store.save("openrouter", value: "  fixture-first\n")
  #expect(try CredentialStore(service: store.service).read("openrouter") == "fixture-first")
  #expect(try store.read("anthropic") == nil)
  try store.save("openrouter", value: "fixture-second")
  #expect(try store.read("openrouter", allowInteraction: false) == "fixture-second")
  try store.remove("openrouter")
  #expect(try store.read("openrouter") == nil)
}

@Test(arguments: [
  errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, OSStatus(-67050),
])
func deniedKeychainReadsAreNotMissingCredentials(_ status: OSStatus) throws {
  #expect(throws: HostError.self) { try CredentialStore.decode(status: status, data: nil) }
  do { _ = try CredentialStore.decode(status: status, data: nil) } catch let error as HostError {
    #expect(error.code == "keychain_error")
    #expect(error.details["status"] == .number(Double(status)))
  }
  #expect(try CredentialStore.decode(status: errSecItemNotFound, data: nil) == nil)
  #expect(throws: HostError.self) {
    try CredentialStore.decode(status: errSecSuccess, data: Data())
  }
}

@Test func modelConnectionRefreshesCredentialsAndKeepsProvidersSeparate() throws {
  let first = try ModelConnection(
    provider: "openrouter", model: "anthropic/test", key: "fixture-first")
  let same = try ModelConnection(
    provider: "openrouter", model: "anthropic/test", key: " fixture-first\n")
  let changed = try ModelConnection(
    provider: "openrouter", model: "anthropic/test", key: "fixture-second")
  #expect(first.fingerprint == same.fingerprint)
  #expect(first.fingerprint != changed.fingerprint)
  #expect(first.environment["ANTHROPIC_API_KEY"] == "")
  #expect(changed.environment["ANTHROPIC_AUTH_TOKEN"] == "fixture-second")
  let direct = try ModelConnection(provider: "anthropic", model: "test", key: "fixture-direct")
  #expect(direct.environment == ["ANTHROPIC_API_KEY": "fixture-direct"])
  #expect(throws: HostError.self) {
    try ModelConnection(provider: "other", model: "test", key: "fixture")
  }
  #expect(throws: HostError.self) {
    try ModelConnection(provider: "anthropic", model: "test?key=bad", key: "fixture")
  }
  #expect(throws: HostError.self) {
    try ModelConnection(provider: "anthropic", model: "test", key: "header\ninjection")
  }
}

private func response(_ request: URLRequest, _ body: String, status: Int = 200) -> (
  Data, URLResponse
) {
  (
    Data(body.utf8),
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
  )
}

@Test func anthropicValidationIsAuthenticatedMetadataOnly() async throws {
  let connection = try ModelConnection(provider: "anthropic", model: "claude-test", key: "fixture")
  let result = try await connection.validate { request in
    #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models/claude-test")
    #expect(request.httpMethod == "GET" && request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    return response(request, #"{"type":"model","id":"claude-test"}"#)
  }
  #expect(result.contains("验证通过") && result.contains("尚未执行模型生成"))
}

@Test func openRouterValidationAuthenticatesBeforeSearchingPagedAccountModels() async throws {
  actor Calls {
    var paths: [String] = []
    func add(_ path: String) { paths.append(path) }
  }
  let calls = Calls()
  let connection = try ModelConnection(
    provider: "openrouter", model: "anthropic/test", key: "fixture")
  _ = try await connection.validate { request in
    #expect(request.httpMethod == "GET" && request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
    let path = request.url!.path
    await calls.add(path)
    if path == "/api/v1/key" { return response(request, #"{"data":{"is_management_key":false}}"#) }
    #expect(path == "/api/v1/models/user")
    if request.url!.query!.contains("offset=0&") {
      return response(
        request,
        #"{"data":["#
          + Array(repeating: #"{"id":"other/model"}"#, count: 100).joined(separator: ",") + "]}")
    }
    #expect(request.url!.query == "offset=100&limit=100")
    return response(request, #"{"data":[{"id":"anthropic/test"}]}"#)
  }
  #expect(await calls.paths == ["/api/v1/key", "/api/v1/models/user", "/api/v1/models/user"])
}

@Test(arguments: [
  (401, "invalid_credentials"), (402, "billing_error"), (403, "permission_denied"),
  (404, "model_unavailable"), (429, "rate_limited"), (503, "provider_error"),
  (302, "provider_error"),
])
func validationReportsSanitizedProviderFailures(_ sample: (Int, String)) async throws {
  let connection = try ModelConnection(
    provider: "openrouter", model: "anthropic/test", key: "fixture-secret")
  do {
    _ = try await connection.validate { request in
      #expect(request.url!.path == "/api/v1/key")
      return response(request, "Do not expose fixture-secret", status: sample.0)
    }
    Issue.record("Expected validation failure")
  } catch let error as HostError {
    #expect(error.code == sample.1)
    #expect(!error.localizedDescription.contains("fixture-secret"))
  }
}

@Test func validationRejectsUnavailableModelsAndMalformedSuccess() async throws {
  let connection = try ModelConnection(
    provider: "openrouter", model: "anthropic/test", key: "fixture")
  do {
    _ = try await connection.validate { request in
      response(
        request,
        request.url!.path == "/api/v1/key"
          ? #"{"data":{"is_management_key":false}}"# : #"{"data":[]}"#)
    }
    Issue.record("Unknown model accepted")
  } catch let error as HostError { #expect(error.code == "model_unavailable") }
  do {
    _ = try await connection.validate { request in response(request, "<html>login</html>") }
    Issue.record("Invalid response accepted")
  } catch let error as HostError { #expect(error.code == "invalid_response") }
  do {
    _ = try await connection.validate { request in
      response(request, #"{"data":{"is_management_key":true}}"#)
    }
    Issue.record("Management key accepted")
  } catch let error as HostError { #expect(error.code == "invalid_credentials") }
}

@Test func validationHandlesTimeoutAndCancellation() async throws {
  let connection = try ModelConnection(provider: "anthropic", model: "test", key: "fixture")
  do {
    _ = try await connection.validate { _ in throw URLError(.timedOut) }
    Issue.record("Timeout accepted")
  } catch let error as HostError { #expect(error.code == "network_error") }
  do {
    _ = try await connection.validate { _ in throw URLError(.cancelled) }
    Issue.record("Cancellation accepted")
  } catch is CancellationError {}
}

@Test func keychainAsyncIOCanTimeOutAndCancelWithoutLateCompletion() async throws {
  let blocked = DispatchSemaphore(value: 0)
  do {
    let _: String = try await CredentialStore.perform(timeout: 0.005) {
      blocked.wait()
      return "late-result"
    }
    Issue.record("Timed out Keychain read succeeded")
  } catch let error as HostError { #expect(error.code == "keychain_timeout") }
  blocked.signal()
  let cancelledGate = DispatchSemaphore(value: 0)
  let cancelled = Task {
    try await CredentialStore.perform {
      cancelledGate.wait()
      return "cancelled-result"
    }
  }
  cancelled.cancel()
  do {
    _ = try await cancelled.value
    Issue.record("Cancelled Keychain read succeeded")
  } catch is CancellationError {}
  cancelledGate.signal()
  // The late callback from a timed-out operation must not resume its continuation twice.
  let recovered = try await CredentialStore.perform { "next-operation" }
  #expect(recovered == "next-operation")
}
