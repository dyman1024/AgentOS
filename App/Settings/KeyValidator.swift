import Foundation

/// Checks an API key with a cheap authenticated request before it is saved.
enum KeyValidator {
    enum Outcome {
        case valid(String)
        case invalid(String)
        /// Could not tell (network error, unexpected status); the key is saved anyway.
        case unknown(String)
    }

    static func validate(_ key: String, for provider: Provider) async -> Outcome {
        var request: URLRequest
        switch provider {
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openRouter:
            request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                return .valid(provider == .openRouter ? openRouterDetail(data) : "Key 有效")
            case 401, 403:
                return .invalid("Key 无效（HTTP \(status)），未保存")
            default:
                return .unknown("无法确认 Key 是否有效（HTTP \(status)），已保存")
            }
        } catch {
            return .unknown("无法连接 \(provider.label)（\(error.localizedDescription)），已保存")
        }
    }

    /// GET /api/v1/key returns the key's spending limit and usage.
    private static func openRouterDetail(_ data: Data) -> String {
        guard let info = (try? JSON.parse(data))?["data"] else { return "Key 有效" }
        if let remaining = info["limit_remaining"]?.double {
            return String(format: "Key 有效 · 剩余额度 $%.2f", remaining)
        }
        if let usage = info["usage"]?.double {
            return String(format: "Key 有效 · 已用 $%.2f", usage)
        }
        return "Key 有效"
    }
}
