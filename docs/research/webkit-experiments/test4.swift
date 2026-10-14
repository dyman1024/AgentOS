import AppKit
import WebKit
let js = "function fib(n){return n<2?n:fib(n-1)+fib(n-2)}; const t0=performance.now(); let s=0; for(let i=0;i<3e7;i++){s=(s+i*7)%1000003}; const v=fib(30)+s; return [v, Math.round(performance.now()-t0)];"
final class D: NSObject, WKNavigationDelegate {
  var done: (WKWebView) -> Void = { _ in }
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done(w) }
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
var keep: [AnyObject] = []
func run(_ label: String, restrict: Bool, next: @escaping () -> Void) {
  let cfg = WKWebViewConfiguration()
  if restrict { if #available(macOS 26.5, *) { cfg.defaultWebpagePreferences.securityRestrictionMode = .maximizeCompatibility } }
  let d = D(); let wv = WKWebView(frame: .init(x: 0, y: 0, width: 100, height: 100), configuration: cfg); wv.navigationDelegate = d
  keep += [d, wv]
  d.done = { w in Task { @MainActor in
    let r = try? await w.callAsyncJavaScript(js, contentWorld: .page)
    print(label, r ?? "nil"); next() } }
  wv.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://example.invalid/"))
}
run("WKWebView default:", restrict: false) { run("WKWebView securityRestrictionMode=.maximizeCompatibility:", restrict: true) { exit(0) } }
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("timeout"); exit(1) }
app.run()
