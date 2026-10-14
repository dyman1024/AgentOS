import Foundation

struct AppManifest: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var icon: String
    var createdAt: Date
    var updatedAt: Date
    /// Agent session to resume for follow-up requests about this app.
    var sessionId: String?
}

/// Saved apps, newest first. Manifests live in meta/<appId>/manifest.json.
@Observable
final class AppRegistry {
    private(set) var apps: [AppManifest] = []

    func load() {
        let fm = FileManager.default
        let ids = (try? fm.contentsOfDirectory(atPath: Paths.meta.path)) ?? []
        apps = ids.compactMap { id in
            let url = Paths.metaDir(id).appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? Self.decoder.decode(AppManifest.self, from: data)
        }
        sort()
    }

    func manifest(_ id: String) -> AppManifest? {
        apps.first { $0.id == id }
    }

    func create() -> AppManifest {
        let now = Date()
        let manifest = AppManifest(id: UUID().uuidString.lowercased(), title: "新应用", icon: "✨", createdAt: now, updatedAt: now)
        try? FileManager.default.createDirectory(at: Paths.appDir(manifest.id), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Paths.metaDir(manifest.id), withIntermediateDirectories: true)
        apps.insert(manifest, at: 0)
        save(manifest)
        return manifest
    }

    func update(_ id: String, _ change: (inout AppManifest) -> Void) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        change(&apps[index])
        apps[index].updatedAt = Date()
        save(apps[index])
        sort()
    }

    func delete(_ id: String) {
        apps.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Paths.appDir(id))
        try? FileManager.default.removeItem(at: Paths.metaDir(id))
    }

    private func save(_ manifest: AppManifest) {
        let url = Paths.metaDir(manifest.id).appendingPathComponent("manifest.json")
        if let data = try? Self.encoder.encode(manifest) { try? data.write(to: url, options: .atomic) }
    }

    private func sort() {
        apps.sort { $0.updatedAt > $1.updatedAt }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
