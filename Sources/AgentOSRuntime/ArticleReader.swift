import AgentOSCore
import Foundation
import WebKit

/// Parses already-fetched HTML without scripts, network, login state or an application bridge.
@MainActor public final class ArticleReader: NSObject, WKNavigationDelegate {
  private var view: WKWebView?
  private var loaded = false
  private var failure: Error?
  public func extract(html: String, url: String) async throws -> Value {
    guard html.utf8.count <= 2_000_000 else {
      throw HostError("too_large", "Article exceeds parser limit")
    }
    let source = try String(
      contentsOf: RuntimeResources.libraryFile("readability.js"), encoding: .utf8)
    let value = try await process(
      html: html, url: url, script: source + ";return globalThis.agentosReadArticle();",
      arguments: [:])
    let title = value["title"]?.string ?? ""
    let text = value["text"]?.string ?? ""
    return [
      "title": .string(title), "markdown": .string("# " + title + "\n\n" + text),
      "text": .string(text), "url": .string(url), "links": value["links"] ?? [],
      "excerpt": value["excerpt"] ?? "", "byline": value["byline"] ?? "", "trust": "untrusted",
    ]
  }
  public func parseMail(_ raw: String) async throws -> Value {
    guard raw.utf8.count <= 2_000_000 else {
      throw HostError("too_large", "Message exceeds parser limit")
    }
    let source = try String(contentsOf: RuntimeResources.libraryFile("mail.js"), encoding: .utf8)
    return try await process(
      html: "", url: "https://mail.invalid/",
      script: source + ";return await globalThis.agentosParseMail(raw);", arguments: ["raw": raw])
  }
  private func process(html: String, url: String, script: String, arguments: [String: Any])
    async throws -> Value
  {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    config.preferences.inactiveSchedulingPolicy = .none
    let rules = try await WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: "agentos-article-no-network-v1",
      encodedContentRuleList:
        "[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]")
    guard let rules else { throw HostError("unavailable", "Article isolation unavailable") }
    config.userContentController.add(rules)
    let view = WKWebView(frame: .zero, configuration: config)
    self.view = view
    view.navigationDelegate = self
    defer {
      view.stopLoading()
      view.navigationDelegate = nil
      self.view = nil
    }
    loaded = false
    failure = nil
    view.loadHTMLString(
      "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'\">"
        + html, baseURL: URL(string: url))
    let deadline = Date().addingTimeInterval(10)
    while !loaded {
      if let failure { throw failure }
      guard Date() < deadline else { throw HostError("timeout", "Article parser timed out") }
      try await Task.sleep(for: .milliseconds(20))
    }
    let result = try await view.callAsyncJavaScript(
      script, arguments: arguments, in: nil, contentWorld: .world(name: "agentos-isolated-parser"))
    return try Value.parse(
      String(
        decoding: JSONSerialization.data(
          withJSONObject: result ?? NSNull(), options: [.fragmentsAllowed]), as: UTF8.self))
  }
  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
  public func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) { failure = error }
  public func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) { failure = error }
  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    failure = HostError("unavailable", "Article parser stopped")
  }
  public func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    decisionHandler(!loaded && navigationAction.navigationType == .other ? .allow : .cancel)
  }
}
