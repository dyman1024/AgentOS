import AgentOSCore
import Foundation
import Observation

@MainActor @Observable final class ModelSettings {
  private let defaults: UserDefaults
  private let credentials: CredentialStore
  private let environmentValues: [String: String]
  var provider: String { didSet { defaults.set(provider, forKey: "provider") } }
  var model: String { didSet { defaults.set(model, forKey: "model") } }
  var budget: Double { didSet { defaults.set(budget, forKey: "budget") } }
  var effort: String { didSet { defaults.set(effort, forKey: "effort") } }
  init(
    defaults: UserDefaults = .standard, credentials: CredentialStore = CredentialStore(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.defaults = defaults
    self.credentials = credentials
    self.environmentValues = environment
    provider = defaults.string(forKey: "provider") ?? "anthropic"
    model = defaults.string(forKey: "model") ?? "claude-opus-5-5"
    budget = defaults.object(forKey: "budget") as? Double ?? 3
    effort = defaults.string(forKey: "effort") ?? "medium"
  }
  var restrictedModel: Bool { provider != "anthropic" && !model.hasPrefix("anthropic/") }
  func credential(_ account: String, allowInteraction: Bool = true) throws -> String? {
    if let value = try credentials.read(account, allowInteraction: allowInteraction) {
      return value
    }
    let variable = [
      "anthropic": "ANTHROPIC_API_KEY", "openrouter": "OPENROUTER_API_KEY",
      "brave": "BRAVE_SEARCH_API_KEY", "github": "AGENTOS_GITHUB_TOKEN",
    ][account]
    guard let variable,
      let value = environmentValues[variable]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    return value
  }
  func key() async throws -> String? {
    let provider = provider
    return try await credentials.readAsync(provider) ?? environmentKey(provider)
  }
  func saveKey(_ key: String) async throws {
    _ = try ModelConnection(provider: provider, model: model, key: key)
    try await credentials.saveAsync(provider, value: key)
  }
  func removeCredential(_ account: String) throws { try credentials.remove(account) }
  func saveCredential(_ account: String, value: String) throws {
    try credentials.save(account, value: value)
  }
  func credentialStatus() async -> String {
    let provider = provider
    do {
      if try await credentials.containsAsync(provider) { return "当前服务商的 Key 已保存；点击验证检查读取与连接。" }
      return environmentKey(provider) != nil ? "使用开发环境提供的 API Key，尚未保存到钥匙串。" : "尚未保存当前服务商的 API Key。"
    } catch { return error.localizedDescription }
  }
  private func environmentKey(_ provider: String) -> String? {
    let variable = provider == "anthropic" ? "ANTHROPIC_API_KEY" : "OPENROUTER_API_KEY"
    let value = environmentValues[variable]?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }
  func connection() async throws -> ModelConnection {
    let provider = provider
    let model = model
    guard let key = try await credentials.readAsync(provider) ?? environmentKey(provider) else {
      throw HostError("missing_credentials", "请先在设置中保存当前服务商的 API Key，并验证连接。")
    }
    return try ModelConnection(provider: provider, model: model, key: key)
  }
}
