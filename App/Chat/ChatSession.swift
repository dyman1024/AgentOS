import Foundation

/// One row in the chat transcript.
@Observable
final class ChatEntry: Identifiable {
    enum Kind: String, Codable { case user, assistant, tool, status, error }
    enum ToolState: String, Codable { case running, done, failed }

    let id = UUID()
    let kind: Kind
    var text: String
    // Tool rows only
    var toolUseId = ""
    var toolName = ""
    var detail = ""
    var state: ToolState = .running
    var codeTail = ""

    init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// The conversation about one app, plus mapping of engine updates onto transcript rows.
@Observable
final class ChatSession {
    let appId: String
    private(set) var entries: [ChatEntry] = []
    var isRunning = false
    var turnStartedAt: Date?
    /// Shown under the working indicator while the API is being retried; cleared once output resumes.
    var retryNotice: String?
    /// Bumped on every change so the transcript can stay scrolled to the bottom.
    private(set) var revision = 0

    init(appId: String) {
        self.appId = appId
        load()
    }

    func append(_ kind: ChatEntry.Kind, _ text: String) {
        entries.append(ChatEntry(kind: kind, text: text))
        revision += 1
    }

    // MARK: Engine updates

    func appendAssistantText(_ text: String) {
        retryNotice = nil
        if let last = entries.last, last.kind == .assistant {
            last.text += text
        } else {
            entries.append(ChatEntry(kind: .assistant, text: text.trimmingLeadingNewlines()))
        }
        revision += 1
    }

    func startTool(id: String, name: String) {
        retryNotice = nil
        let entry = tool(id: id) ?? {
            let e = ChatEntry(kind: .tool, text: ToolPresentation.title(for: name, input: nil))
            e.toolUseId = id
            e.toolName = name
            entries.append(e)
            return e
        }()
        entry.state = .running
        revision += 1
    }

    func toolProgress(id: String, name: String, path: String?, lines: Int, tail: String) {
        if tool(id: id) == nil { startTool(id: id, name: name) }
        guard let entry = tool(id: id) else { return }
        if let path { entry.text = ToolPresentation.title(for: name, input: ["path": .string(path)]) }
        entry.detail = "\(lines) 行"
        entry.codeTail = tail
        revision += 1
    }

    func toolCall(id: String, name: String, input: JSON) {
        if tool(id: id) == nil { startTool(id: id, name: name) }
        guard let entry = tool(id: id) else { return }
        entry.text = ToolPresentation.title(for: name, input: input)
        if let lines = input["content_lines"]?.int ?? input["new_string_lines"]?.int { entry.detail = "\(lines) 行" }
        revision += 1
    }

    func toolResult(id: String, isError: Bool, text: String) {
        guard let entry = tool(id: id) else { return }
        entry.state = isError ? .failed : .done
        entry.codeTail = ""
        if isError { entry.detail = String(text.prefix(200)) }
        revision += 1
    }

    /// Runtime tools are executed by the host, so the host fills in their result summary.
    func annotateLatestTool(named name: String, detail: String) {
        guard let entry = entries.last(where: { $0.kind == .tool && $0.toolName == name && $0.state == .running }) else { return }
        entry.detail = detail
        revision += 1
    }

    func finishTurn() {
        for entry in entries where entry.kind == .tool && entry.state == .running {
            entry.state = .done
            entry.codeTail = ""
        }
        isRunning = false
        turnStartedAt = nil
        retryNotice = nil
        revision += 1
        save()
    }

    private func tool(id: String) -> ChatEntry? {
        entries.last { $0.kind == .tool && $0.toolUseId == id }
    }

    // MARK: Persistence (meta/<appId>/chat.json)

    private struct Record: Codable {
        var kind: ChatEntry.Kind
        var text: String
        var toolName: String?
        var detail: String?
        var state: ChatEntry.ToolState?
    }

    private var fileURL: URL { Paths.metaDir(appId).appendingPathComponent("chat.json") }

    func save() {
        let records = entries.map {
            Record(kind: $0.kind, text: $0.text, toolName: $0.kind == .tool ? $0.toolName : nil,
                   detail: $0.detail.isEmpty ? nil : $0.detail, state: $0.kind == .tool ? $0.state : nil)
        }
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: fileURL, options: .atomic) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        entries = records.map { r in
            let e = ChatEntry(kind: r.kind, text: r.text)
            e.toolName = r.toolName ?? ""
            e.detail = r.detail ?? ""
            e.state = r.state ?? .done
            return e
        }
    }
}

/// How tool calls are labelled in the chat.
enum ToolPresentation {
    static func shortName(_ name: String) -> String {
        name.hasPrefix("mcp__runtime__") ? String(name.dropFirst("mcp__runtime__".count)) : name
    }

    static func title(for name: String, input: JSON?) -> String {
        let path = input?["path"]?.string ?? input?["pattern"]?.string
        switch shortName(name) {
        case "Write": return "写入 \(path ?? "文件")"
        case "Edit": return "修改 \(path ?? "文件")"
        case "Read": return "读取 \(path ?? "文件")"
        case "Glob": return "查找文件"
        case "run_app": return "运行应用"
        case "smoke_test": return "冒烟测试"
        case "send_input": return "模拟输入"
        case "get_console": return "读取日志"
        case "screenshot": return "截图检查"
        case "inspect_state": return "读取状态"
        case "set_app_info": return "命名应用"
        default: return shortName(name)
        }
    }

    static func symbol(for name: String) -> String {
        switch shortName(name) {
        case "Write": "square.and.pencil"
        case "Edit": "pencil.line"
        case "Read": "doc.text"
        case "Glob": "magnifyingglass"
        case "run_app": "play.fill"
        case "smoke_test": "checkmark.seal"
        case "send_input": "keyboard"
        case "get_console": "list.bullet.rectangle"
        case "screenshot": "camera.viewfinder"
        case "inspect_state": "scope"
        case "set_app_info": "tag"
        default: "wrench.and.screwdriver"
        }
    }
}

private extension String {
    func trimmingLeadingNewlines() -> String {
        String(drop { $0 == "\n" })
    }
}
