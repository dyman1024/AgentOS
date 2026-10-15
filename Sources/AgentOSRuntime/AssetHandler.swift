import AgentOSCore
import Foundation
import UniformTypeIdentifiers
import WebKit

@MainActor final class AssetHandler: NSObject, WKURLSchemeHandler {
  let appID: String, directory: URL, corePath: String
  weak var owner: WKWebView?
  static let csp =
    "default-src 'none'; script-src agentos: 'unsafe-inline' 'wasm-unsafe-eval' blob:; style-src agentos: 'unsafe-inline'; img-src agentos: data: blob:; media-src agentos: data: blob:; font-src agentos: data:; connect-src agentos: data: blob:; worker-src agentos: blob:; base-uri 'none'; form-action 'none'"
  init(appID: String, directory: URL, corePath: String) {
    self.appID = appID
    self.directory = directory
    self.corePath = corePath
  }
  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard webView === owner, let url = task.request.url, url.scheme == "agentos", url.host == appID,
      url.port == nil,
      url.user == nil, url.password == nil,
      UUID(uuidString: appID)?.uuidString.lowercased() == appID
    else {
      task.didFailWithError(HostError("denied", "Origin mismatch"))
      return
    }
    do {
      let data: Data
      let type: String
      if url.path.hasPrefix("/_lib/") {
        let path = try RuntimeResources.libraryFile(String(url.path.dropFirst(6)))
        data = try Data(contentsOf: path)
        type = path.pathExtension == "css" ? "text/css" : "text/javascript"
      } else if url.path == "/_host/core.html" {
        let core = URL(string: "agentos://\(appID)/")!.appendingPathComponent(corePath)
          .absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(
            of: "\"", with: "&quot;")
        data = Data(
          "<!doctype html><meta charset=\"utf-8\"><script type=\"module\" src=\"\(core)\"></script>"
            .utf8)
        type = "text/html"
      } else {
        let relative = String(url.path.dropFirst())
        let path = try SafePath.resolve(relative, under: directory)
        guard
          try path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]).isRegularFile == true
        else { throw HostError("denied", "Not a regular file") }
        data = try Data(contentsOf: path)
        type =
          path.pathExtension == "js"
          ? "text/javascript"
          : UTType(filenameExtension: path.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
      }
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Type": type, "Content-Security-Policy": Self.csp,
          "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store",
        ])!
      task.didReceive(response)
      task.didReceive(data)
      task.didFinish()
    } catch { task.didFailWithError(error) }
  }
  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
