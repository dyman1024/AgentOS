import UniformTypeIdentifiers
import WebKit

/// Serves `agentos://<appId>/<path>` from the app's folder on disk.
/// Every response carries a CSP that blocks all network access and external resources.
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

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let appId = url.host?.lowercased(), !appId.isEmpty else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let base = Paths.appDir(appId).standardizedFileURL
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = base.appendingPathComponent(String(path.dropFirst())).standardizedFileURL

        guard file.path.hasPrefix(base.path + "/") else {
            respond(task, url: url, status: 403, mime: "text/plain", body: Data("Forbidden".utf8))
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
