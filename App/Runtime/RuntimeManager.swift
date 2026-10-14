import SwiftUI
import WebKit

/// Creates and keeps one sandboxed runtime per generated app.
@Observable
final class RuntimeManager {
    private(set) var controllers: [String: RuntimeController] = [:]
    private let schemeHandler = AppSchemeHandler()
    private var blockNetwork: WKContentRuleList?

    private static let shimSource: String = {
        guard let url = Bundle.main.url(forResource: "agentos-shim", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { fatalError("agentos-shim.js missing from the app bundle") }
        return source
    }()

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
        controllers[appId] = controller
        return controller
    }

    func remove(_ appId: String) {
        controllers.removeValue(forKey: appId)?.tearDown()
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
        config.mediaTypesRequiringUserActionForPlayback = []
        let content = config.userContentController
        content.addUserScript(WKUserScript(source: Self.shimSource, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let blockNetwork { content.add(blockNetwork) }
        return config
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
