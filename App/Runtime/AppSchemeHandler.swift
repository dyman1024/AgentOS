import UniformTypeIdentifiers
import WebKit

/// Serves `agentos://<appId>/<path>` from the app's folder on disk.
/// Every response carries a CSP that blocks all network access and external resources.
///
/// One handler serves every web view, so each request is checked against the web view that made it:
/// the host must be a registered app ID in canonical UUID form and must equal the app that web view
/// is bound to. Anything else (`agentos://..`, another app's ID, an unbound web view) gets a 403.
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "agentos"

    static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src agentos: 'unsafe-inline' blob:",
        "style-src agentos: 'unsafe-inline'",
        "img-src agentos: data: blob:",
        "media-src agentos: data: blob:",
        "font-src agentos: data:",
        "connect-src agentos: data: blob:",
        "worker-src agentos: blob:",
        "base-uri 'none'",
        "form-action 'none'",
    ].joined(separator: "; ")

    private struct Binding {
        weak var webView: WKWebView?
        let appId: String
    }

    private let registry: AppRegistry
    private var bindings: [ObjectIdentifier: Binding] = [:]

    init(registry: AppRegistry) {
        self.registry = registry
    }

    /// Records which app a web view belongs to. Requests from web views that were never bound are refused.
    func bind(_ webView: WKWebView, to appId: String) {
        bindings = bindings.filter { $0.value.webView != nil }
        bindings[ObjectIdentifier(webView)] = Binding(webView: webView, appId: appId)
    }

    func unbind(_ webView: WKWebView) {
        bindings.removeValue(forKey: ObjectIdentifier(webView))
    }

    /// The app the requesting web view is bound to. The identity check guards against a reused object address.
    private func appId(for webView: WKWebView) -> String? {
        guard let binding = bindings[ObjectIdentifier(webView)], binding.webView === webView else { return nil }
        return binding.appId
    }

    /// True for the canonical lowercase UUID form the registry uses for app IDs.
    static func isAppId(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let boundAppId = appId(for: webView)
        guard let appId = boundAppId, url.host == appId, url.port == nil,
              Self.isAppId(appId), registry.manifest(appId) != nil
        else {
            Log.event("scheme_request_denied", [
                "url": .string(String(url.absoluteString.prefix(300))), "appId": boundAppId.map(JSON.string) ?? .null,
            ])
            forbid(task, url: url)
            return
        }
        // Resolve symlinks too, so a link planted in the app folder cannot point outside it.
        let base = Paths.appDir(appId).resolvingSymlinksInPath()
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = base.appendingPathComponent(String(path.dropFirst())).resolvingSymlinksInPath()

        guard file.path.hasPrefix(base.path + "/") else {
            forbid(task, url: url)
            return
        }
        if let data = try? Data(contentsOf: file) {
            respond(task, url: url, status: 200, mime: Self.mimeType(for: file), body: data)
        } else if path == "/index.html" {
            // A new app has no files yet; show a placeholder until the agent writes index.html.
            respond(task, url: url, status: 200, mime: "text/html", body: Data(Self.placeholder.utf8))
        } else {
            respond(task, url: url, status: 404, mime: "text/plain", body: Data("Not found: \(path)".utf8))
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func forbid(_ task: any WKURLSchemeTask, url: URL) {
        respond(task, url: url, status: 403, mime: "text/plain", body: Data("Forbidden".utf8))
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, status: Int, mime: String, body: Data) {
        let headers = [
            "Content-Type": mime,
            "Content-Length": String(body.count),
            "Cache-Control": "no-store",
            "Content-Security-Policy": Self.contentSecurityPolicy,
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    private static func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "wasm": return "application/wasm"
        default: return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    private static let placeholder = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;height:100%;background:#0f1115;color:#8b93a7;font:15px -apple-system,system-ui;
        display:flex;align-items:center;justify-content:center}
        .dot{width:10px;height:10px;border-radius:50%;background:#5b8cff;margin:0 auto 16px;animation:p 1.2s ease-in-out infinite}
        @keyframes p{0%,100%{opacity:.25;transform:scale(.8)}50%{opacity:1;transform:scale(1.2)}}
        </style></head><body><div><div class="dot"></div>正在生成应用…</div></body></html>
        """
}
