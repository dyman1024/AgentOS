import AppKit
import SwiftUI
import WebKit

let html = #"""
<!doctype html><html><body style="margin:0;background:#00f">
<script>
window.agentos = { ask: (q) => window.webkit.messageHandlers.os.postMessage({q}) };
(async () => {
  const r = {};
  r.img = await new Promise(res => { const i = new Image(); i.onload = () => res('loaded'); i.onerror = () => res('blocked'); i.src = 'https://www.apple.com/favicon.ico?' + Math.random(); });
  try { await fetch('https://esm.sh/', {mode:'no-cors'}); r.fetch = 'allowed'; } catch(e) { r.fetch = 'blocked'; }
  r.ws = await new Promise(res => { try { const w = new WebSocket('wss://echo.websocket.org'); w.onopen=()=>res('open'); w.onerror=()=>res('error'); setTimeout(()=>res('timeout'),3000);} catch(e){res('threw')} });
  r.reply = await window.agentos.ask('ping');
  window.__r = r;
})();
</script></body></html>
"""#

struct Handler: URLSchemeHandler {
  func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
    AsyncThrowingStream { c in
      c.yield(.response(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!))
      c.yield(.data(Data(html.utf8)))
      c.finish()
    }
  }
}

final class OS: NSObject, WKScriptMessageHandlerWithReply {
  func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
    replyHandler(["pong": true, "isMain": m.frameInfo.isMainFrame], nil)
  }
}

@MainActor func main() async {
  let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
  let list = try! await WKContentRuleListStore.default()!.compileContentRuleList(forIdentifier: "block-net", encodedContentRuleList: rules)!

  var cfg = WebPage.Configuration()
  cfg.urlSchemeHandlers[URLScheme("agentos")!] = Handler()
  cfg.websiteDataStore = .nonPersistent()
  cfg.userContentController.addScriptMessageHandler(OS(), contentWorld: .page, name: "os")
  cfg.userContentController.add(list)
  let t0 = Date()
  let page = WebPage(configuration: cfg)
  let host = NSHostingView(rootView: WebView(page).frame(width: 300, height: 200))
  let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
  win.contentView = host; win.orderFront(nil)
  do {
    for try await ev in page.load(URL(string: "agentos://app/index.html")!) { if ev == .finished { print("WebPage finished in \(Int(Date().timeIntervalSince(t0)*1000)) ms") } }
  } catch { print("load error", error) }
  try? await Task.sleep(for: .seconds(4))
  let r = try? await page.callJavaScript("return JSON.stringify(window.__r) + ' / arg=' + x", arguments: ["x": 41 + 1])
  print("callJavaScript ->", r ?? "nil")
  if let png = try? await page.exported(as: .image(region: .contents)) , let rep = NSBitmapImageRep(data: png), let c = rep.colorAt(x: 5, y: 5) {
    print("exported image \(rep.pixelsWide)x\(rep.pixelsHigh) pixel b=\(String(format: "%.2f", c.blueComponent))")
  } else { print("export failed") }
  exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in await main() }
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("timeout"); exit(1) }
app.run()
