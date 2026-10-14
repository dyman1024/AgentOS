import Foundation

/// On-disk layout under ~/Library/Application Support/AgentOS.
///   apps/<appId>/        the generated app's files; the agent's working directory
///   meta/<appId>/        manifest.json and chat.json, kept outside the agent's reach
///   agent/               isolated Claude config dir (session transcripts); user settings never leak in
///   logs/                JSONL event logs, one file per launch
nonisolated enum Paths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AgentOS", isDirectory: true)
    }()

    static let apps = root.appendingPathComponent("apps", isDirectory: true)
    static let meta = root.appendingPathComponent("meta", isDirectory: true)
    static let logs = root.appendingPathComponent("logs", isDirectory: true)
    static let agentConfig = root.appendingPathComponent("agent", isDirectory: true)

    static func appDir(_ appId: String) -> URL {
        apps.appendingPathComponent(appId, isDirectory: true)
    }

    static func metaDir(_ appId: String) -> URL {
        meta.appendingPathComponent(appId, isDirectory: true)
    }

    static func ensure() {
        for dir in [apps, meta, logs, agentConfig] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
