import AgentOSCore
import AppKit
import WebKit

@MainActor
public final class WebInstance: NSObject, WKNavigationDelegate, WKUIDelegate,
  WKScriptMessageHandlerWithReply
{
  public let app: InstalledApp
  public let webView: WKWebView
  public let isCore: Bool
  public let instanceID: String
  public private(set) var registered: Set<String> = []
  public private(set) var console: [Value] = []
  public var context: RequestContext?
  public var lastUsed = Date()
  public var onRequest: ((String, Value, RequestContext) async throws -> Value)?
  public var onSubscription: ((String) async throws -> Void)?
  public var invalidated = false
  var loaded = false, failure: Error?
  private let assets: AssetHandler
  public static let world = WKContentWorld.world(name: "agentos-trusted-host")
  public init(
    app: InstalledApp, directory: URL, isCore: Bool, temporary: Bool = false,
    instanceID: String? = nil
  ) async throws {
    self.app = app
    self.isCore = isCore
    self.instanceID = instanceID ?? "\(app.id)/\(isCore ? "core" : "ui")/\(UUID().uuidString)"
    let config = WKWebViewConfiguration()
    config.websiteDataStore =
      temporary ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: UUID(uuidString: app.id)!)
    config.preferences.inactiveSchedulingPolicy = isCore ? .none : .suspend
    let selector = NSSelectorFromString("_setPeerConnectionEnabled:")
    guard config.preferences.responds(to: selector) else {
      throw HostError("unavailable", "WebRTC sandbox is unavailable on this WebKit build")
    }
    config.preferences.setValue(false, forKey: "peerConnectionEnabled")
    let block = try await WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: "agentos-deny-network-v2",
      encodedContentRuleList:
        "[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}},{\"trigger\":{\"url-filter\":\"^wss?://\"},\"action\":{\"type\":\"block\"}}]"
    )
    guard let block else { throw HostError("unavailable", "Could not install network sandbox") }
    config.userContentController.add(block)
    let denyRTC =
      "for(const k of ['RTCPeerConnection','webkitRTCPeerConnection','RTCDataChannel','RTCIceCandidate','RTCSessionDescription']){try{Object.defineProperty(globalThis,k,{value:undefined,writable:false,configurable:false})}catch{}}"
    config.userContentController.addUserScript(
      WKUserScript(source: denyRTC, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    for (name, world) in [("host", Self.world), ("sdk", WKContentWorld.page)] {
      let source = try String(
        contentsOf: Bundle.module.url(forResource: name, withExtension: "js")!, encoding: .utf8)
      config.userContentController.addUserScript(
        WKUserScript(
          source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
    }
    assets = AssetHandler(
      appID: app.id, directory: directory,
      corePath: app.manifest["runtime"]?["core"]?.string ?? "core.js")
    config.setURLSchemeHandler(assets, forURLScheme: "agentos")
    webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 680), configuration: config)
    super.init()
    assets.owner = webView
    config.userContentController.addScriptMessageHandler(
      self, contentWorld: Self.world, name: "host")
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.underPageBackgroundColor = .black
    let path =
      isCore ? "_host/core.html" : app.manifest["runtime"]?["ui"]?.string ?? "ui/index.html"
    webView.load(URLRequest(url: URL(string: "agentos://\(app.id)/")!.appendingPathComponent(path)))
  }
  public func ready() async throws {
    let until = Date().addingTimeInterval(10)
    let expected = Set(try AppInterface(app.interface).tools.map(\.name))
    while !loaded || (isCore && registered != expected) {
      if let failure { throw failure }
      guard !invalidated, Date() < until else {
        throw HostError("unavailable", "Core did not register all declared tools")
      }
      try await Task.sleep(for: .milliseconds(25))
    }
  }
  public func close() {
    invalidated = true
    context = nil
    webView.stopLoading()
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: "host", contentWorld: Self.world)
  }
  public func invoke(kind: String = "tool", name: String, args: Value) async throws -> Value {
    guard !invalidated else { throw HostError("unavailable", "Runtime was discarded") }
    lastUsed = Date()
    let result = try await evaluate(
      "return await window.__aosHost.invoke(kind,name,args)",
      arguments: ["kind": .string(kind), "name": .string(name), "args": args])
    if let error = result["error"] {
      throw HostError(
        error["code"]?.string ?? "app_error", error["message"]?.string ?? "Application failed")
    }
    return result["result"] ?? .null
  }
  public func evaluate(_ script: String, arguments: [String: Value] = [:]) async throws -> Value {
    let result = try await webView.callAsyncJavaScript(
      script, arguments: arguments.mapValues(\.foundation), in: nil, contentWorld: Self.world)
    return try Value.parse(
      String(
        decoding: JSONSerialization.data(
          withJSONObject: result ?? NSNull(), options: [.fragmentsAllowed]), as: UTF8.self))
  }
  public func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage,
    replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
  ) {
    guard !invalidated, message.webView === webView, message.frameInfo.isMainFrame,
      message.frameInfo.securityOrigin.host == app.id,
      message.frameInfo.securityOrigin.protocol == "agentos"
    else {
      replyHandler(["error": ["code": "denied", "message": "Unbound frame"]], nil)
      return
    }
    Task { @MainActor in
      do {
        let body = try Value.parse(
          String(decoding: JSONSerialization.data(withJSONObject: message.body), as: UTF8.self))
        let method = try body.requiredString("method")
        let args = body["args"] ?? [:]
        var result: Value = ["ok": true]
        if method == "console" {
          console.append(args)
          if console.count > 300 { console.removeFirst() }
        } else if method == "tools.register" {
          let name = try args.requiredString("name")
          guard isCore, try AppInterface(app.interface).tools.contains(where: { $0.name == name }),
            !registered.contains(name)
          else { throw HostError("denied", "Handler is not declared or already registered") }
          registered.insert(name)
        } else if method == "events.subscribe" {
          guard isCore, let onSubscription else {
            throw HostError("denied", "Only a core may subscribe")
          }
          try await onSubscription(args.requiredString("pattern"))
        } else {
          guard let context, let onRequest else {
            throw HostError("denied", "No active host invocation")
          }
          result = try await onRequest(method, args, context)
        }
        replyHandler(["result": result.foundation], nil)
      } catch {
        let e = (error as? HostError) ?? HostError("app_error", error.localizedDescription)
        replyHandler(
          ["error": ["code": e.code, "message": e.message, "details": e.details.foundation]], nil)
      }
    }
  }
  public func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async
    -> WKNavigationActionPolicy
  {
    guard let url = action.request.url else { return .cancel }
    let own = url.scheme == "agentos" && url.host == app.id && url.port == nil && url.user == nil
    let blank = url.absoluteString == "about:blank"
    let srcdoc = action.targetFrame?.isMainFrame == false && url.absoluteString == "about:srcdoc"
    return own || blank || srcdoc ? .allow : .cancel
  }
  public func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
  public func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error)
  { failure = error }
  public func webView(
    _ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) { failure = error }
  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    failure = HostError("unavailable", "Application process terminated")
    close()
  }
  public func webView(
    _ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for action: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? { nil }
}
