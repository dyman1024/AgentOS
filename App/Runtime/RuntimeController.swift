import AppKit
import WebKit

/// WKWebView tuned for games: takes keyboard focus on click.
final class GameWebView: WKWebView {
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

/// Console entry captured from a running app.
struct ConsoleEntry {
    let seq: Int
    let level: String
    let message: String
    let file: String?
    let line: Int?
    let stack: String?

    var json: JSON {
        var o: [String: JSON] = ["seq": .number(Double(seq)), "level": .string(level), "msg": .string(message)]
        if let file { o["file"] = .string(file) }
        if let line { o["line"] = .number(Double(line)) }
        if let stack, !stack.isEmpty { o["stack"] = .string(String(stack.prefix(1500))) }
        return .object(o)
    }
}

/// Owns the web view for one generated app and implements the runtime tools the agent calls.
final class RuntimeController: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let appId: String
    let webView: GameWebView

    private(set) var console: [ConsoleEntry] = []
    private var nextSeq = 1
    private var navigationWaiters: [ObjectIdentifier: CheckedContinuation<String?, Never>] = [:]
    private var pendingAutoReload: Task<Void, Never>?

    var entryURL: URL { URL(string: "\(AppSchemeHandler.scheme)://\(appId)/index.html")! }

    init(appId: String, configuration: WKWebViewConfiguration) {
        self.appId = appId
        webView = GameWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.configuration.userContentController.add(WeakMessageHandler(self), name: "agentosLog")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        webView.underPageBackgroundColor = .black
    }

    /// First load. The owner binds the web view to this app in the scheme handler before calling it.
    func start() {
        webView.load(URLRequest(url: entryURL))
    }

    func tearDown() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "agentosLog")
        webView.stopLoading()
    }

    // MARK: - Loading

    /// Reload shortly after a file change; coalesces bursts of edits.
    func scheduleAutoReload() {
        pendingAutoReload?.cancel()
        pendingAutoReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            _ = await self.load()
        }
    }

    /// Loads the entry page and waits for it to finish. Returns an error description, or nil on success.
    @discardableResult
    func load(timeout: Duration = .seconds(10)) async -> String? {
        pendingAutoReload?.cancel()
        guard let navigation = webView.load(URLRequest(url: entryURL)) else { return "navigation did not start" }
        let key = ObjectIdentifier(navigation)
        return await withCheckedContinuation { continuation in
            navigationWaiters[key] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.navigationWaiters.removeValue(forKey: key)?.resume(returning: "load timed out")
            }
        }
    }

    func focus() {
        webView.window?.makeFirstResponder(webView)
    }

    // MARK: - Runtime tools

    func runApp() async -> JSON {
        let seq0 = nextSeq
        let start = ContinuousClock.now
        let error = await load()
        let loadMs = (ContinuousClock.now - start).milliseconds
        try? await Task.sleep(for: .milliseconds(1000))
        let entries = console.filter { $0.seq >= seq0 }
        return [
            "loaded": .bool(error == nil),
            "load_error": error.map(JSON.string) ?? .null,
            "load_ms": .number(Double(loadMs)),
            "errors": .array(entries.filter { $0.level == "error" }.prefix(10).map(\.json)),
            "warnings": .array(entries.filter { $0.level == "warn" }.prefix(5).map(\.json)),
            "logs": .array(entries.filter { $0.level == "log" }.prefix(10).map(\.json)),
            "exposes_state": .bool(await evaluate("return window.__agentos ? window.__agentos.hasExposed() : false").bool ?? false),
            "visibility": await evaluate("return document.visibilityState"),
        ]
    }

    static let allChecks = ["no_errors", "nonblank", "frames_advancing", "visual_change", "state_changes"]

    func smokeTest(_ args: JSON) async -> JSON {
        let checks = args["checks"]?.array?.compactMap(\.string) ?? Self.allChecks
        let inputs = args["inputs"]?.array ?? []
        let duration = Duration.milliseconds(args["duration_ms"]?.int ?? 2500)
        let seq0 = nextSeq

        var loadError: String?
        if args["reload"]?.bool ?? true {
            loadError = await load()
            try? await Task.sleep(for: .milliseconds(600))
        }

        let start = ContinuousClock.now
        let frames0 = await evaluate("return window.__agentos ? window.__agentos.frames() : -1").int ?? -1
        let before = await snapshotSample()
        let stateBefore = await state()
        for step in inputs { await perform(step) }
        let remaining = duration - (ContinuousClock.now - start)
        if remaining > .zero { try? await Task.sleep(for: remaining) }
        let frames1 = await evaluate("return window.__agentos ? window.__agentos.frames() : -1").int ?? -1
        let after = await snapshotSample()
        let stateAfter = await state()
        let seconds = Double((ContinuousClock.now - start).milliseconds) / 1000

        let errors = console.filter { $0.seq >= seq0 && $0.level == "error" }
        // WebKit pauses rendering and requestAnimationFrame while the window is hidden or fully covered,
        // so pixel and frame checks would report false failures. Skip them rather than mislead the agent.
        let visible = await evaluate("return document.visibilityState").string == "visible"
        let visualChecks: Set<String> = ["nonblank", "frames_advancing", "visual_change"]
        var results: [String: JSON] = [:]
        for check in checks {
            if !visible && visualChecks.contains(check) {
                results[check] = ["pass": .null, "skipped": true, "detail": "skipped: the AgentOS window is hidden or covered, so rendering is paused"]
                continue
            }
            switch check {
            case "no_errors":
                let ok = errors.isEmpty && loadError == nil
                results[check] = ["pass": .bool(ok), "detail": .string(ok ? "no errors" : "\(errors.count) error(s)\(loadError.map { ", load: \($0)" } ?? "")")]
            case "nonblank":
                let share = after?.dominantColorShare ?? 1
                results[check] = ["pass": .bool(share < 0.9995), "detail": .string(String(format: "%.2f%% of the screen differs from the background color", (1 - share) * 100))]
            case "frames_advancing":
                let delta = frames0 >= 0 && frames1 >= 0 ? frames1 - frames0 : 0
                results[check] = ["pass": .bool(delta >= 10), "detail": .string("\(delta) animation frames in \(String(format: "%.1f", seconds))s")]
            case "visual_change":
                let share = (before != nil && after != nil) ? after!.changedShare(comparedTo: before!) : 0
                results[check] = ["pass": .bool(share > 0.001), "detail": .string(String(format: "%.2f%% of pixels changed", share * 100))]
            case "state_changes":
                if stateBefore.isNull && stateAfter.isNull {
                    results[check] = ["pass": false, "detail": "agentos.expose() was never called, so state cannot be inspected"]
                } else {
                    results[check] = ["pass": .bool(stateBefore != stateAfter), "detail": .string(stateBefore != stateAfter ? "state changed" : "state identical before and after inputs")]
                }
            default:
                results[check] = ["pass": false, "detail": .string("unknown check")]
            }
        }
        let pass = results.values.allSatisfy { $0["skipped"]?.bool == true || $0["pass"]?.bool == true }
        let fps = frames0 >= 0 && frames1 >= 0 && seconds > 0 ? Double(frames1 - frames0) / seconds : 0
        return [
            "pass": .bool(pass),
            "visible": .bool(visible),
            "checks": .object(results),
            "fps": .number((fps * 10).rounded() / 10),
            "errors": .array(errors.prefix(10).map(\.json)),
            "state_before": stateBefore,
            "state_after": stateAfter,
        ]
    }

    func sendInput(_ args: JSON) async -> JSON {
        let seq0 = nextSeq
        for step in args["steps"]?.array ?? [] { await perform(step) }
        try? await Task.sleep(for: .milliseconds(150))
        return [
            "console": .array(console.filter { $0.seq >= seq0 }.prefix(20).map(\.json)),
            "state": await state(),
        ]
    }

    func consoleEntries(_ args: JSON) -> JSON {
        let since = args["since_seq"]?.int ?? 0
        let levels = Set(args["levels"]?.array?.compactMap(\.string) ?? ["error", "warn", "log"])
        let limit = args["limit"]?.int ?? 50
        let entries = console.filter { $0.seq > since && levels.contains($0.level) }.suffix(limit)
        return ["entries": .array(entries.map(\.json)), "last_seq": .number(Double(nextSeq - 1))]
    }

    func screenshot(maxPixels: CGFloat = 1024) async throws -> JSON {
        let image = try await webView.takeSnapshot(configuration: nil)
        guard let (png, _, _) = image.pngData(maxPixels: maxPixels) else { throw RuntimeError.snapshotFailed }
        return [
            "pngBase64": .string(png.base64EncodedString()),
            "width": .number(Double(webView.bounds.width.rounded())),
            "height": .number(Double(webView.bounds.height.rounded())),
        ]
    }

    func state() async -> JSON {
        await evaluate("return window.__agentos ? window.__agentos.state() : null")
    }

    // MARK: - Helpers

    enum RuntimeError: LocalizedError {
        case snapshotFailed
        var errorDescription: String? { "截图失败" }
    }

    private func perform(_ step: JSON) async {
        let action = step["action"]?.string ?? "press"
        let key = step["key"]?.string ?? ""
        switch action {
        case "wait":
            try? await Task.sleep(for: .milliseconds(step["ms"]?.int ?? 100))
        case "down", "up":
            _ = await evaluate("window.__agentos.key(type, key)", ["type": .string(action == "down" ? "keydown" : "keyup"), "key": .string(key)])
        case "click":
            _ = await evaluate("window.__agentos.click(x, y)", ["x": .number(step["x"]?.double ?? 0), "y": .number(step["y"]?.double ?? 0)])
            try? await Task.sleep(for: .milliseconds(50))
        default:
            _ = await evaluate("window.__agentos.key('keydown', key)", ["key": .string(key)])
            try? await Task.sleep(for: .milliseconds(step["ms"]?.int ?? 80))
            _ = await evaluate("window.__agentos.key('keyup', key)", ["key": .string(key)])
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private func snapshotSample() async -> PixelSample? {
        guard let image = try? await webView.takeSnapshot(configuration: nil) else { return nil }
        return PixelSample(image)
    }

    private func evaluate(_ body: String, _ arguments: [String: JSON] = [:]) async -> JSON {
        do {
            // The host world sees the same DOM but not the app's globals, so the app cannot fake these results.
            let value = try await webView.callAsyncJavaScript(
                body, arguments: arguments.mapValues(\.foundation), in: nil, contentWorld: RuntimeManager.hostWorld)
            return JSON(any: value)
        } catch {
            return .null
        }
    }

    private func append(level: String, message: String, file: String? = nil, line: Int? = nil, stack: String? = nil) {
        console.append(ConsoleEntry(seq: nextSeq, level: level, message: message, file: file, line: line, stack: stack))
        nextSeq += 1
        if console.count > 1000 { console.removeFirst(console.count - 1000) }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the app's own top-level document may report; sandboxed iframes can reach handlers too.
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == appId else { return }
        let body = JSON(any: message.body)
        let file = body["file"]?.string.map { $0.replacingOccurrences(of: "\(AppSchemeHandler.scheme)://\(appId)/", with: "") }
        append(
            level: body["level"]?.string ?? "log", message: body["msg"]?.string ?? "",
            file: file, line: body["line"]?.int, stack: body["stack"]?.string)
    }

    // MARK: - WKNavigationDelegate

    /// The main frame may only show this app's own origin or about:blank, so an app cannot switch origin by
    /// navigating (to `agentos://..`, another app, or an opaque data:/blob: document). Subframes may also use
    /// about:srcdoc; anything else they try is already refused by the CSP (`frame-src` falls back to 'none').
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        // A nil target frame means a new window, which createWebViewWith refuses anyway.
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        if isOwnOrigin(url) || Self.isAbout(url, "blank") || (!isMainFrame && Self.isAbout(url, "srcdoc")) {
            return .allow
        }
        let shown = url.absoluteString.count > 200 ? url.absoluteString.prefix(200) + "…" : Substring(url.absoluteString)
        append(level: "error", message: "Navigation blocked by the AgentOS sandbox: \(shown)")
        Log.event("navigation_blocked", ["appId": .string(appId), "url": .string(String(shown)), "mainFrame": .bool(isMainFrame)])
        return .cancel
    }

    private func isOwnOrigin(_ url: URL) -> Bool {
        url.scheme == AppSchemeHandler.scheme && url.host == appId && url.port == nil
    }

    /// `about:<page>`, optionally followed by a query or fragment.
    private static func isAbout(_ url: URL, _ page: String) -> Bool {
        let s = url.absoluteString
        let end = s.firstIndex { $0 == "#" || $0 == "?" } ?? s.endIndex
        return s[..<end] == "about:" + page
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationWaiters.removeValue(forKey: ObjectIdentifier(navigation))?.resume(returning: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        navigationWaiters.removeValue(forKey: ObjectIdentifier(navigation))?.resume(returning: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        navigationWaiters.removeValue(forKey: ObjectIdentifier(navigation))?.resume(returning: error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        append(level: "error", message: "The app's web content process crashed or was killed (possibly an infinite loop or out of memory). Reloading.")
        Log.event("runtime_process_terminated", ["appId": .string(appId)])
        webView.load(URLRequest(url: entryURL))
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}

/// Breaks the retain cycle between WKUserContentController and its message handler.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

extension Duration {
    var milliseconds: Int64 {
        let (s, attos) = components
        return s * 1000 + attos / 1_000_000_000_000_000
    }
}
