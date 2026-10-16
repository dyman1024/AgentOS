import AgentOSCore
import AgentOSRuntime
import AppKit
import Observation
import SwiftUI
import WebKit

/// User browsing is a separate surface; applications and Agents have no read API for it.
@MainActor @Observable final class NativeBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
  let view: WKWebView
  var address: String
  var notice = ""
  var sharing = false
  var window: NSWindow?
  let share: (String, String) -> Void
  init(url: String, share: @escaping (String, String) -> Void) {
    address = url
    self.share = share
    let config = WKWebViewConfiguration()
    config.websiteDataStore = WKWebsiteDataStore(
      forIdentifier: UUID(uuidString: "ad540d9f-64cc-490f-9d52-bd98605f165e")!)
    view = WKWebView(frame: .zero, configuration: config)
    super.init()
    view.navigationDelegate = self
    view.uiDelegate = self
  }
  func show() {
    let window = NSWindow(
      contentRect: NSRect(x: 160, y: 160, width: 1100, height: 760),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = "AgentOS 浏览器"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: BrowserChrome(browser: self))
    window.makeKeyAndOrderFront(nil)
    self.window = window
    go()
  }
  func go() {
    guard let url = URL(string: address), ["https", "http"].contains(url.scheme), url.user == nil,
      url.password == nil
    else {
      notice = "请输入 HTTP 或 HTTPS 地址"
      return
    }
    view.load(URLRequest(url: url))
  }
  func sharePage() {
    guard !sharing, let url = view.url?.absoluteString else { return }
    sharing = true
    Task {
      defer { sharing = false }
      do {
        let script = try String(
          contentsOf: RuntimeResources.libraryFile("readability.js"), encoding: .utf8)
        let value = try await view.callAsyncJavaScript(
          script + ";return globalThis.agentosReadArticle().text;", arguments: [:], in: nil,
          contentWorld: .world(name: "agentos-user-share"))
        guard let text = value as? String else { throw HostError("unavailable", "无法提取此页面") }
        share(url, String(text.prefix(80000)))
        notice = "已将本页交给 Agent"
      } catch { notice = error.localizedDescription }
    }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    address = webView.url?.absoluteString ?? address
    window?.title = webView.title ?? "浏览器"
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let scheme = action.request.url?.scheme ?? ""
    decisionHandler(["http", "https", "about"].contains(scheme) ? .allow : .cancel)
  }
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for action: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = action.request.url, ["http", "https"].contains(url.scheme) {
      view.load(action.request)
    }
    return nil
  }
}
struct BrowserChrome: View {
  @Bindable var browser: NativeBrowser
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button {
          browser.view.goBack()
        } label: {
          Image(systemName: "chevron.left")
        }
        Button {
          browser.view.reload()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        TextField("网址", text: $browser.address).onSubmit { browser.go() }
        Button(browser.sharing ? "提取中…" : "把这一页交给 Agent") { browser.sharePage() }.disabled(
          browser.sharing)
      }.padding(10)
      BrowserWebView(view: browser.view)
      HStack {
        Text(browser.notice.isEmpty ? "登录状态独立保存。只有点击分享按钮，Agent 才能读取当前页面。" : browser.notice).font(
          .caption
        ).foregroundStyle(.secondary)
        Spacer()
      }.padding(8)
    }
  }
}
struct BrowserWebView: NSViewRepresentable {
  let view: WKWebView
  func makeNSView(context: Context) -> WKWebView { view }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}
