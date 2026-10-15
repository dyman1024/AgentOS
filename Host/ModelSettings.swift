import AgentOSCore
import Foundation
import Observation
import Security

@MainActor @Observable final class ModelSettings {
  private let defaults = UserDefaults.standard
  var provider: String { didSet { defaults.set(provider, forKey: "provider") } }
  var model: String { didSet { defaults.set(model, forKey: "model") } }
  var budget: Double { didSet { defaults.set(budget, forKey: "budget") } }
  var effort: String { didSet { defaults.set(effort, forKey: "effort") } }
  init() {
    provider = defaults.string(forKey: "provider") ?? "anthropic"
    model = defaults.string(forKey: "model") ?? "claude-opus-5-5"
    budget = defaults.object(forKey: "budget") as? Double ?? 3
    effort = defaults.string(forKey: "effort") ?? "medium"
  }
  var restrictedModel: Bool { provider != "anthropic" && !model.hasPrefix("anthropic/") }
  func credential(_ account: String) -> String? {
    var query = Self.query(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    {
      return String(data: data, encoding: .utf8)
    }
    let variable = [
      "anthropic": "ANTHROPIC_API_KEY", "openrouter": "OPENROUTER_API_KEY",
      "brave": "BRAVE_SEARCH_API_KEY", "github": "AGENTOS_GITHUB_TOKEN",
    ][account]
    return variable.flatMap { ProcessInfo.processInfo.environment[$0] }
  }
  func key() -> String? { credential(provider) }
  func saveKey(_ key: String) throws { try saveCredential(provider, value: key) }
  func removeCredential(_ account: String) throws {
    let status = SecItemDelete(Self.query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw HostError("keychain_error", "钥匙串删除失败（\(status)）")
    }
  }
  func saveCredential(_ account: String, value key: String) throws {
    let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    guard !data.isEmpty else { throw HostError("invalid_args", "请输入 API Key") }
    var query = Self.query(account)
    var status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      query[kSecValueData as String] = data
      query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(query as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw HostError("keychain_error", "钥匙串保存失败（\(status)）") }
  }
  private static func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dev.agentos.AgentOSRebuild", kSecAttrAccount as String: account,
    ]
  }
  func environment() throws -> [String: String] {
    guard let key = key(), !key.isEmpty else { throw HostError("unavailable", "请先在设置中保存 API Key") }
    if provider == "anthropic" { return ["ANTHROPIC_API_KEY": key] }
    return [
      "ANTHROPIC_BASE_URL": "https://openrouter.ai/api", "ANTHROPIC_AUTH_TOKEN": key,
      "ANTHROPIC_API_KEY": "", "ANTHROPIC_CUSTOM_HEADERS": "X-Title: AgentOS",
      "ANTHROPIC_DEFAULT_HAIKU_MODEL": model,
    ]
  }
}
