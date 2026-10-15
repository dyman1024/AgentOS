import AppKit
import SwiftUI

/// Root state: wires the chat, the agent engine and the per-app runtimes together.
@Observable
final class AppModel {
    let registry: AppRegistry
    let runtime: RuntimeManager
    let settings = AppSettings()
    @ObservationIgnored private let engine = EngineClient()

    /// The app shown in the runtime pane; nil shows the launcher, and the next prompt creates a new app.
    private(set) var currentAppId: String?
    private var sessions: [String: ChatSession] = [:]
    /// Chat for the launcher state, before a prompt has created an app.
    let draftSession = ChatSession(appId: "")
    var alert: String?

    var currentApp: AppManifest? { currentAppId.flatMap(registry.manifest) }
    var currentSession: ChatSession { currentAppId.map(session) ?? draftSession }
    var currentWebView: GameWebView? { currentAppId.flatMap { runtime.controllers[$0]?.webView } }

    init() {
        let registry = AppRegistry()
        self.registry = registry
        runtime = RuntimeManager(registry: registry)
        engine.onNotification = { [weak self] method, params in self?.handleNotification(method, params) }
        engine.onRequest = { [weak self] method, params in
            guard let self else { return .null }
            return try await self.handleRuntimeRequest(method, params)
        }
    }

    func start() async {
        Paths.ensure()
        registry.load()
        await runtime.prepare()
        Log.event("launched", ["apps": .number(Double(registry.apps.count)), "log": .string(Log.fileURL.path)])
        await DevAutomation.runIfRequested(self)
    }

    func session(for appId: String) -> ChatSession {
        if let s = sessions[appId] { return s }
        let s = ChatSession(appId: appId)
        sessions[appId] = s
        return s
    }

    // MARK: - App selection

    func showLauncher() {
        currentAppId = nil
    }

    func open(_ appId: String) {
        _ = runtime.controller(for: appId)
        currentAppId = appId
    }

    func delete(_ appId: String) {
        if currentAppId == appId { currentAppId = nil }
        runtime.remove(appId)
        sessions.removeValue(forKey: appId)
        registry.delete(appId)
    }

    func reloadCurrent() {
        guard let id = currentAppId else { return }
        Task { await runtime.controller(for: id).load() }
    }

    /// Restarts the engine on the next prompt, e.g. after the API key changed.
    func resetEngine() {
        engine.stop()
    }

    // MARK: - Prompting

    func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let apiKey = settings.apiKey else {
            alert = "请先在「设置」中填写 \(settings.provider.label) API Key（⌘,）"
            return
        }

        let appId: String
        if let id = currentAppId {
            appId = id
        } else {
            appId = registry.create().id
            open(appId)
        }
        let session = session(for: appId)
        guard !session.isRunning else { return }
        session.append(.user, text)
        session.isRunning = true
        session.turnStartedAt = Date()

        do {
            if !engine.isRunning { try engine.start(environment: settings.engineEnvironment(apiKey: apiKey)) }
            if settings.provider == .openRouter { await OpenRouterCatalog.shared.loadIfNeeded() }
            let params: JSON = [
                "appId": .string(appId),
                "appDir": .string(Paths.appDir(appId).path),
                "text": .string(text),
                "sessionId": registry.manifest(appId)?.sessionId.map(JSON.string) ?? .null,
                "model": .string(settings.model),
                "effort": settings.effectiveEffort.map(JSON.string) ?? .null,
                "vision": .bool(settings.modelSupportsVision),
                "maxBudgetUsd": .number(settings.maxBudgetUsd),
            ]
            Log.event("prompt", [
                "appId": .string(appId), "text": .string(text), "provider": .string(settings.provider.rawValue),
                "model": .string(settings.model),
            ])
            let result = try await engine.request("session/prompt", params)
            Log.event("prompt_result", ["appId": .string(appId), "result": result])
            if let sid = result["sessionId"]?.string { registry.update(appId) { $0.sessionId = sid } }
            session.append(result["isError"]?.bool == true ? .error : .status, summary(of: result))
        } catch {
            Log.error("prompt failed: \(error.localizedDescription)")
            session.append(.error, friendly(error))
        }
        session.finishTurn()
        if currentAppId == appId { runtime.controllers[appId]?.focus() }
    }

    func cancel() {
        guard let id = currentAppId else { return }
        engine.notify("session/cancel", ["appId": .string(id)])
    }

    private func friendly(_ error: Error) -> String {
        let message = error.localizedDescription
        let provider = settings.provider.label
        let lowered = message.lowercased()
        if lowered.contains("invalid api key") || lowered.contains("authentication_error")
            || lowered.contains("authentication_failed") || lowered.contains("401") || lowered.contains("no auth credentials")
            || lowered.contains("user not found") {
            return "\(provider) API Key 无效，请在「设置」(⌘,) 中检查后重试。\n\(message)"
        }
        if lowered.contains("credit balance") || lowered.contains("insufficient credits") || lowered.contains("billing_error")
            || lowered.contains("402") {
            return "\(provider) 账户余额不足。\n\(message)"
        }
        if lowered.contains("model_not_found")
            || lowered.contains("model") && (lowered.contains("not found") || lowered.contains("not a valid") || lowered.contains("404")) {
            return "\(provider) 上找不到模型「\(settings.model)」，请在设置中更换。\n\(message)"
        }
        return message
    }

    private func summary(of result: JSON) -> String {
        if result["cancelled"]?.bool == true { return "已停止" }
        let seconds = Int((result["durationMs"]?.double ?? 0) / 1000)
        // Claude Code prices usage from Anthropic's list prices; through OpenRouter it is only an estimate.
        let estimate = settings.provider == .openRouter ? "（估算，以 OpenRouter 账单为准）" : ""
        let cost = result["costUsd"]?.double.flatMap { $0 > 0 ? String(format: " · $%.2f%@", $0, estimate) : nil } ?? ""
        if result["isError"]?.bool == true {
            let reason = result["resultText"]?.string ?? result["subtype"]?.string ?? "未知错误"
            return "出错了：\(reason)"
        }
        return "完成 · 用时 \(seconds) 秒\(cost)"
    }

    // MARK: - Engine → host

    private func handleNotification(_ method: String, _ params: JSON) {
        guard method == "session/update", let appId = params["appId"]?.string, let u = params["update"] else { return }
        let session = session(for: appId)
        let id = u["toolUseId"]?.string ?? ""
        let name = u["name"]?.string ?? ""
        switch u["kind"]?.string {
        case "session_started":
            if let sid = u["sessionId"]?.string { registry.update(appId) { $0.sessionId = sid } }
        case "text_delta":
            session.appendAssistantText(u["text"]?.string ?? "")
        case "tool_start":
            session.startTool(id: id, name: name)
        case "tool_progress":
            session.toolProgress(id: id, name: name, path: u["path"]?.string, lines: u["lines"]?.int ?? 0, tail: u["tail"]?.string ?? "")
        case "tool_call":
            session.toolCall(id: id, name: name, input: u["input"] ?? .null)
        case "tool_result":
            session.toolResult(id: id, isError: u["isError"]?.bool ?? false, text: u["text"]?.string ?? "")
        case "api_retry":
            let status = u["status"]?.int.map { "HTTP \($0)" } ?? (u["error"]?.string ?? "网络错误")
            session.retryNotice = "请求失败（\(status)），正在重试 \(u["attempt"]?.int ?? 0)/\(u["maxRetries"]?.int ?? 0)…"
        case "file_changed":
            runtime.controller(for: appId).scheduleAutoReload()
        default:
            break
        }
    }

    private func handleRuntimeRequest(_ method: String, _ params: JSON) async throws -> JSON {
        guard let appId = params["appId"]?.string, registry.manifest(appId) != nil else {
            throw EngineClient.EngineError.remote("unknown app")
        }
        let controller = runtime.controller(for: appId)
        let session = session(for: appId)
        let tool = "mcp__runtime__" + method.replacingOccurrences(of: "runtime/", with: "")
        Log.event("runtime_call", ["appId": .string(appId), "method": .string(method)])

        switch method {
        case "runtime/run_app":
            let r = await controller.runApp()
            let errors = r["errors"]?.array?.count ?? 0
            session.annotateLatestTool(named: tool, detail: r["loaded"]?.bool != true ? "加载失败" : errors == 0 ? "加载成功 · 无报错" : "\(errors) 个错误")
            return r
        case "runtime/smoke_test":
            let r = await controller.smokeTest(params)
            let checks = r["checks"]?.object ?? [:]
            let failed = checks.filter { $0.value["pass"]?.bool == false }.map(\.key).sorted()
            let skipped = checks.contains { $0.value["skipped"]?.bool == true }
            let fps = r["fps"]?.double ?? 0
            let summary = failed.isEmpty ? (skipped ? "通过（窗口不可见，跳过画面检查）" : "通过 · \(Int(fps)) fps") : "未通过：\(failed.joined(separator: ", "))"
            session.annotateLatestTool(named: tool, detail: summary)
            Log.event("smoke_test", ["appId": .string(appId), "result": r])
            return r
        case "runtime/send_input":
            return await controller.sendInput(params)
        case "runtime/get_console":
            return controller.consoleEntries(params)
        case "runtime/screenshot":
            let r = try await controller.screenshot()
            session.annotateLatestTool(named: tool, detail: "已截图")
            return r
        case "runtime/inspect_state":
            return ["state": await controller.state()]
        case "runtime/set_app_info":
            let title = params["title"]?.string ?? "应用"
            let icon = params["icon"]?.string ?? "✨"
            registry.update(appId) { $0.title = title; $0.icon = icon }
            session.annotateLatestTool(named: tool, detail: "\(icon) \(title)")
            return ["ok": true]
        default:
            throw EngineClient.EngineError.remote("unknown runtime method \(method)")
        }
    }
}
