import CryptoKit
import Foundation

public struct ModelConnection: Sendable {
  public let provider: String
  public let model: String
  private let key: String

  public init(provider: String, model: String, key: String) throws {
    guard ["anthropic", "openrouter"].contains(provider) else {
      throw HostError("invalid_args", "请选择支持的模型服务商。")
    }
    let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, key.utf8.count <= 4096,
      key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 })
    else { throw HostError("invalid_args", "API Key 不能为空，也不能包含空格、换行或非 ASCII 字符。") }
    guard !model.isEmpty, model.utf8.count <= 200,
      model.range(of: "^[A-Za-z0-9][A-Za-z0-9._:/-]*$", options: .regularExpression) != nil
    else { throw HostError("invalid_args", "请输入有效的模型 ID。") }
    self.provider = provider
    self.model = model
    self.key = key
  }

  public var restrictedModel: Bool { provider != "anthropic" && !model.hasPrefix("anthropic/") }

  /// Memory-only identity: replacing a credential must restart the sidecar before the next run.
  public var fingerprint: String {
    SHA256.hash(data: Data((provider + "\n" + model + "\n" + key).utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
  public var environment: [String: String] {
    if provider == "anthropic" { return ["ANTHROPIC_API_KEY": key] }
    return [
      "ANTHROPIC_BASE_URL": "https://openrouter.ai/api", "ANTHROPIC_AUTH_TOKEN": key,
      "ANTHROPIC_API_KEY": "", "ANTHROPIC_CUSTOM_HEADERS": "X-Title: AgentOS",
      "ANTHROPIC_DEFAULT_HAIKU_MODEL": model,
    ]
  }

  public var authorizationHeaders: [String: String] {
    provider == "anthropic"
      ? ["x-api-key": key, "anthropic-version": "2023-06-01"]
      : ["Authorization": "Bearer " + key]
  }

  public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  /// Read-only authentication and model discovery. Never calls a generation endpoint.
  public func validate(transport: Transport? = nil) async throws -> String {
    let send = transport ?? Self.fetch
    if provider == "anthropic" {
      let result = try await get(
        "https://api.anthropic.com/v1/models/" + model,
        headers: authorizationHeaders, send: send)
      guard result["type"] == "model", result["id"]?.string?.isEmpty == false else {
        throw HostError("invalid_response", "服务商未返回有效的模型信息。")
      }
    } else {
      let headers = authorizationHeaders
      let result = try await get("https://openrouter.ai/api/v1/key", headers: headers, send: send)
      guard let credential = result["data"]?.object, !credential.isEmpty else {
        throw HostError("invalid_response", "服务商未返回有效的凭据信息。")
      }
      guard credential["is_management_key"] != true, credential["is_provisioning_key"] != true
      else {
        throw HostError("invalid_credentials", "这是管理 Key，请使用用于模型调用的 API Key。")
      }
      for offset in stride(from: 0, to: 2000, by: 100) {
        let catalog = try await get(
          "https://openrouter.ai/api/v1/models/user?offset=\(offset)&limit=100",
          headers: headers, send: send)
        guard let models = catalog["data"]?.array else {
          throw HostError("invalid_response", "服务商未返回有效的模型列表。")
        }
        if models.contains(where: { $0["id"]?.string == model }) { return success }
        if models.count < 100 {
          throw HostError("model_unavailable", "API Key 有效，但所选模型不在当前账户的可用列表中。请检查模型 ID、服务商和账户限制。")
        }
      }
      throw HostError("validation_incomplete", "API Key 有效，但模型列表过大，未能完成模型检查。")
    }
    return success
  }
  private var success: String { "验证通过：API Key 有效，所选模型可查询。尚未执行模型生成，余额和实际生成能力未验证。" }

  private func get(_ url: String, headers: [String: String], send: Transport) async throws -> Value
  {
    try Task.checkCancellation()
    var request = URLRequest(
      url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    request.httpMethod = "GET"
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let data: Data
    let response: URLResponse
    do { (data, response) = try await send(request) } catch let error as URLError {
      if error.code == .cancelled { throw CancellationError() }
      throw HostError(
        "network_error", error.code == .timedOut ? "验证超时，请检查网络后重试。" : "无法连接服务商，请检查网络、代理或 TLS 连接后重试。"
      )
    }
    try Task.checkCancellation()
    guard let response = response as? HTTPURLResponse else {
      throw HostError("invalid_response", "服务商响应无效。")
    }
    switch response.statusCode {
    case 200: break
    case 401: throw HostError("invalid_credentials", "API Key 无效、已过期或已撤销，请检查服务商并重新保存。")
    case 402: throw HostError("billing_error", "服务商提示额度不足，请检查账户或 Key 的预算限制。")
    case 403: throw HostError("permission_denied", "服务商拒绝访问，请检查 Key 权限、账户和地区限制。")
    case 404: throw HostError("model_unavailable", "模型或验证接口不存在，请检查模型 ID 和服务商。")
    case 429: throw HostError("rate_limited", "服务商请求过于频繁，请稍后重试。")
    default: throw HostError("provider_error", "服务商验证失败（HTTP \(response.statusCode)），请稍后重试。")
    }
    guard data.count <= 4_000_000,
      let result = try? JSONDecoder().decode(Value.self, from: data), result.object != nil
    else { throw HostError("invalid_response", "服务商返回的验证数据无效或过大。") }
    return result
  }

  private static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForResource = 20
    let session = URLSession(
      configuration: configuration, delegate: CredentialRedirectPolicy(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    return try await session.data(for: request)
  }
}

/// Keep credentials at the explicitly configured provider; an HTTP redirect is not authorization.
final class CredentialRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
