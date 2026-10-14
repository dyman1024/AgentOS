import Foundation

/// OpenRouter's public model list (no key needed), used to validate custom model IDs and to learn
/// whether a model accepts images.
@Observable
final class OpenRouterCatalog {
    static let shared = OpenRouterCatalog()

    struct Model: Hashable {
        let id: String
        let name: String
        let vision: Bool
        let inputPerMillion: Double?
        let outputPerMillion: Double?
    }

    private(set) var models: [String: Model] = [:]
    private(set) var isLoading = false
    private(set) var loadError: String?

    var isLoaded: Bool { !models.isEmpty }

    func supportsImages(_ id: String) -> Bool? {
        models[id]?.vision
    }

    func loadIfNeeded() async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
            request.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: request)
            let list = try JSON.parse(data)["data"]?.array ?? []
            var parsed: [String: Model] = [:]
            for m in list {
                guard let id = m["id"]?.string else { continue }
                let inputs = m["architecture"]?["input_modalities"]?.array?.compactMap(\.string) ?? []
                parsed[id] = Model(
                    id: id, name: m["name"]?.string ?? id, vision: inputs.contains("image"),
                    inputPerMillion: m["pricing"]?["prompt"]?.string.flatMap(Double.init).map { $0 * 1_000_000 },
                    outputPerMillion: m["pricing"]?["completion"]?.string.flatMap(Double.init).map { $0 * 1_000_000 })
            }
            models = parsed
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            Log.error("OpenRouter model list failed: \(error.localizedDescription)")
        }
    }
}
