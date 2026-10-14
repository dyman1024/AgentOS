import Foundation
import Security

/// Where model requests go. The engine always speaks the Anthropic Messages API;
/// OpenRouter is reached through its Anthropic-compatible endpoint.
enum Provider: String, CaseIterable, Identifiable {
    case anthropic
    case openRouter = "openrouter"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openRouter: "OpenRouter"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openRouter: "sk-or-v1-…"
        }
    }

    /// Environment variable that supplies the key during development when the Keychain has none.
    var devKeyVariable: String {
        switch self {
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openRouter: "OPENROUTER_API_KEY"
        }
    }
}

struct ModelOption: Identifiable, Hashable {
    let id: String
    let label: String
    /// Whether the model accepts images; without it the agent's screenshot tool is turned off.
    var vision = true
}

/// User preferences. API keys live in the Keychain, one per provider; everything else in UserDefaults.
@Observable
final class AppSettings {
    static let anthropicModels = [
        ModelOption(id: "claude-opus-5-5", label: "Claude Opus 5.5（推荐）"),
        ModelOption(id: "claude-sonnet-5-5", label: "Claude Sonnet 5.5"),
        ModelOption(id: "claude-haiku-5-5", label: "Claude Haiku 5.5"),
        ModelOption(id: "claude-fable-5-1", label: "Claude Fable 5.1"),
    ]
    /// OpenRouter slugs checked against https://openrouter.ai/api/v1/models on 2026-10-15.
    /// Claude Code (which the engine runs on) is tuned for Claude; other models are best-effort.
    static let openRouterModels = [
        ModelOption(id: "anthropic/claude-opus-5.5", label: "Claude Opus 5.5（推荐）"),
        ModelOption(id: "anthropic/claude-sonnet-5.5", label: "Claude Sonnet 5.5"),
        ModelOption(id: "anthropic/claude-haiku-5.5", label: "Claude Haiku 5.5"),
        ModelOption(id: "openai/gpt-6.1-sol", label: "GPT-6.1 Sol（实验性）"),
        ModelOption(id: "google/gemini-4-argon", label: "Gemini 4 Argon（实验性）"),
        ModelOption(id: "moonshotai/kimi-k3", label: "Kimi K3（实验性）"),
        ModelOption(id: "qwen/qwen3.8-max-0902", label: "Qwen3.8 Max（实验性）"),
        ModelOption(id: "deepseek/deepseek-v4-pro", label: "DeepSeek V4 Pro（实验性，无图像）", vision: false),
    ]
    static let efforts: [(id: String, label: String)] = [
        ("low", "低（最快）"), ("medium", "中（默认）"), ("high", "高"), ("xhigh", "很高"),
    ]

    var provider: Provider { didSet { defaults.set(provider.rawValue, forKey: "provider") } }
    var anthropicModel: String { didSet { defaults.set(anthropicModel, forKey: "model") } }
    var openRouterModel: String { didSet { defaults.set(openRouterModel, forKey: "openRouterModel") } }
    var effort: String { didSet { defaults.set(effort, forKey: "effort") } }
    var maxBudgetUsd: Double { didSet { defaults.set(maxBudgetUsd, forKey: "maxBudgetUsd") } }

    private let defaults = UserDefaults.standard
    private var cachedKeys: [Provider: String?] = [:]

    init() {
        provider = Provider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .anthropic
        anthropicModel = defaults.string(forKey: "model") ?? "claude-opus-5-5"
        openRouterModel = defaults.string(forKey: "openRouterModel") ?? "anthropic/claude-opus-5.5"
        effort = defaults.string(forKey: "effort") ?? "medium"
        maxBudgetUsd = defaults.object(forKey: "maxBudgetUsd") as? Double ?? 3
    }

    // MARK: Active configuration

    var model: String {
        get { provider == .anthropic ? anthropicModel : openRouterModel }
        set { if provider == .anthropic { anthropicModel = newValue } else { openRouterModel = newValue } }
    }

    var modelOptions: [ModelOption] {
        provider == .anthropic ? Self.anthropicModels : Self.openRouterModels
    }

    var isClaudeModel: Bool {
        provider == .anthropic || openRouterModel.hasPrefix("anthropic/") || openRouterModel.hasPrefix("~anthropic/")
    }

    /// The effort setting is a Claude API parameter; other models don't get it.
    var effectiveEffort: String? { isClaudeModel ? effort : nil }

    /// Presets know their image support; for a custom OpenRouter ID the catalog decides, defaulting to yes.
    var modelSupportsVision: Bool {
        if let preset = modelOptions.first(where: { $0.id == model }) { return preset.vision }
        return OpenRouterCatalog.shared.supportsImages(model) ?? true
    }

    /// Engine environment for the active provider; nil entries are removed from the inherited environment.
    func engineEnvironment(apiKey: String) -> [String: String?] {
        switch provider {
        case .anthropic:
            return [
                "ANTHROPIC_API_KEY": apiKey,
                "ANTHROPIC_AUTH_TOKEN": nil,
                "ANTHROPIC_BASE_URL": nil,
                "ANTHROPIC_DEFAULT_HAIKU_MODEL": nil,
                "ANTHROPIC_CUSTOM_HEADERS": nil,
            ]
        case .openRouter:
            // https://openrouter.ai/docs/guides/community/anthropic-agent-sdk
            return [
                "ANTHROPIC_BASE_URL": "https://openrouter.ai/api",
                "ANTHROPIC_AUTH_TOKEN": apiKey,
                "ANTHROPIC_API_KEY": "",  // must be explicitly empty, or Claude Code tries Anthropic auth
                // Claude Code runs small background requests on the Haiku tier; keep those on OpenRouter too.
                "ANTHROPIC_DEFAULT_HAIKU_MODEL": "anthropic/claude-haiku-5.5",
                "ANTHROPIC_CUSTOM_HEADERS": "X-Title: AgentOS",
            ]
        }
    }

    // MARK: API keys

    /// Keychain first; the provider's environment variable is a fallback for development runs.
    func apiKey(for provider: Provider) -> String? {
        if let cached = cachedKeys[provider] { return cached }
        let env = ProcessInfo.processInfo.environment[provider.devKeyVariable].flatMap { $0.isEmpty ? nil : $0 }
        let key = Keychain.read(account: Self.keychainAccount(provider)) ?? env
        cachedKeys[provider] = .some(key)
        return key
    }

    var apiKey: String? { apiKey(for: provider) }

    func hasApiKey(for provider: Provider) -> Bool { apiKey(for: provider) != nil }

    func setApiKey(_ key: String?, for provider: Provider) {
        let account = Self.keychainAccount(provider)
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { Keychain.write(trimmed, account: account) } else { Keychain.delete(account: account) }
        cachedKeys[provider] = nil
    }

    private static func keychainAccount(_ provider: Provider) -> String {
        "\(provider.rawValue)-api-key"
    }
}

enum Keychain {
    private static let service = "dev.agentos.AgentOS"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
