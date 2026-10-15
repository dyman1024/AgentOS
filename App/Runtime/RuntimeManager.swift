import SwiftUI
import WebKit

/// Creates and keeps one sandboxed runtime per generated app.
@Observable
final class RuntimeManager {
    /// Content world for the host's test hooks and everything the host evaluates. App code runs in the page
    /// world and can neither see nor replace what lives here.
    static let hostWorld = WKContentWorld.world(name: "agentos-host")

    private(set) var controllers: [String: RuntimeController] = [:]
    private let schemeHandler: AppSchemeHandler
    private var blockNetwork: WKContentRuleList?

    init(registry: AppRegistry) {
        schemeHandler = AppSchemeHandler(registry: registry)
    }

    /// Page world, main frame: console capture and the `agentos` API for app code.
    private static let shimSource = bundledScript("agentos-shim")
    /// Host world, main frame: the `__agentos` hooks the runtime tools call.
    private static let hostHooksSource = bundledScript("agentos-host")
    /// Page world, every frame: backs up the WebRTC preference in case a WebKit update stops honoring it.
    private static let removeWebRTCSource = """
        for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection']) { try { delete window[name]; } catch {} }
        """

    private static func bundledScript(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { fatalError("\(name).js missing from the app bundle") }
        return source
    }

    /// Compiles the content rule list that blocks http(s)/ws(s) as a second layer behind the CSP.
    func prepare() async {
        let rules = """
            [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]
            """
        do {
            blockNetwork = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "agentos-block-network", encodedContentRuleList: rules)
        } catch {
            Log.error("content rule list failed to compile: \(error)")
        }
    }

    func controller(for appId: String) -> RuntimeController {
        if let existing = controllers[appId] { return existing }
        let controller = RuntimeController(appId: appId, configuration: makeConfiguration(appId: appId))
        // Bind before the first load so the scheme handler knows which app this web view may read.
        schemeHandler.bind(controller.webView, to: appId)
        controllers[appId] = controller
        controller.start()
        return controller
    }

    func remove(_ appId: String) {
        if let controller = controllers.removeValue(forKey: appId) {
            schemeHandler.unbind(controller.webView)
            controller.tearDown()
        }
        if let uuid = UUID(uuidString: appId) {
            Task { try? await WKWebsiteDataStore.remove(forIdentifier: uuid) }
        }
    }

    private func makeConfiguration(appId: String) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: AppSchemeHandler.scheme)
        // Each app gets its own persistent storage (localStorage, IndexedDB), isolated from other apps.
        if let uuid = UUID(uuidString: appId) {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: uuid)
        }
        config.preferences.inactiveSchedulingPolicy = .suspend
        Self.disableWebRTC(config.preferences)
        config.mediaTypesRequiringUserActionForPlayback = []
        let content = config.userContentController
        content.addUserScript(WKUserScript(source: Self.shimSource, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(
            source: Self.hostHooksSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.hostWorld))
        content.addUserScript(WKUserScript(source: Self.removeWebRTCSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if let blockNetwork { content.add(blockNetwork) }
        return config
    }

    /// RTCPeerConnection reaches the network around both the CSP and the content rule list, and WKWebView has
    /// no public switch for it. AgentOS ships outside the App Store, so it turns WebRTC off with the private
    /// preference; KVC resolves the key to -[WKPreferences _setPeerConnectionEnabled:].
    private static func disableWebRTC(_ preferences: WKPreferences) {
        guard preferences.responds(to: NSSelectorFromString("_setPeerConnectionEnabled:")) else {
            Log.error("WKPreferences._setPeerConnectionEnabled: is unavailable; WebRTC is only removed by script")
            return
        }
        preferences.setValue(false, forKey: "peerConnectionEnabled")
    }
}

/// Hosts the current app's web view; swapping apps swaps the subview without recreating the representable.
struct RuntimeView: NSViewRepresentable {
    let webView: WKWebView?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard container.subviews.first !== webView else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let webView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
