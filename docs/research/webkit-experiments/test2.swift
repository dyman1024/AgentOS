import AppKit
import WebKit

let html = #"""
<!doctype html><html><head><meta charset="utf-8"></head><body style="margin:0">
<canvas id=c width=200 height=200></canvas>
<script>window.__iframeMsg = new Promise(res => addEventListener("message", e => res(e.data), {once:true}));</script>
<iframe id=f sandbox="allow-scripts" srcdoc="<script>parent.postMessage({inner: typeof window.webkit, handlers: (window.webkit&&window.webkit.messageHandlers)? Object.keys(window.webkit.messageHandlers).length + ':' + typeof window.webkit.messageHandlers.bridge : 'none', origin: location.origin}, '*'); try{ window.webkit.messageHandlers.bridge.postMessage({type:'fromIframe'}) }catch(e){}</script>"></iframe>
<script type="module">
const r = {};
const gl = document.getElementById('c').getContext('webgl2');
gl.clearColor(1,0,0,1); gl.clear(gl.COLOR_BUFFER_BIT);
const ac = new AudioContext(); r.audioBefore = ac.state;
await Promise.race([ac.resume(), new Promise(r=>setTimeout(r,500))]); r.audioAfterResume = ac.state;
r.iframe = await Promise.race([window.__iframeMsg, new Promise(r=>setTimeout(()=>r('no-msg'),1000))]);
try { await fetch('https://esm.sh/', {mode:'no-cors'}); r.noCorsFetch = 'allowed'; } catch(e) { r.noCorsFetch = 'blocked'; }
try { const m = await import('https://esm.sh/canvas-confetti@1.9.3'); r.cdnImport = typeof m.default; } catch(e) { r.cdnImport = 'blocked: ' + e; }
r.img = await new Promise(res => { const i = new Image(); i.onload = () => res('loaded'); i.onerror = () => res('blocked'); i.src = 'https://www.apple.com/favicon.ico?' + Math.random(); });
try { r.wsCtor = (()=>{ const w = new WebSocket('wss://echo.websocket.org'); return 'constructed' })(); } catch(e) { r.wsCtor = 'blocked: ' + e; }
r.ws = await new Promise(res => { try { const w = new WebSocket('wss://echo.websocket.org'); w.onopen=()=>res('open'); w.onerror=()=>res('error'); setTimeout(()=>res('timeout'),3000);} catch(e){res('threw')} });
window.webkit.messageHandlers.bridge.postMessage({type:'final', r});
</script></body></html>
"""#

final class SchemeHandler: NSObject, WKURLSchemeHandler {
  let csp: String
  init(csp: String) { self.csp = csp }
  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    let url = task.request.url!
    var headers = ["Content-Type": "text/html"]
    if !csp.isEmpty { headers["Content-Security-Policy"] = csp }
    task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
    task.didReceive(Data(html.utf8)); task.didFinish()
  }
  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  let label: String; var onFinal: ([String: Any]) -> Void = { _ in }
  var t = Date(); var onFinish: () -> Void = {}
  init(label: String) { self.label = label }
  func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
    let d = message.body as? [String: Any] ?? [:]
    if d["type"] as? String == "fromIframe" {
      print("[\(label)] message from iframe! frame isMain=\(message.frameInfo.isMainFrame) origin=\(message.frameInfo.securityOrigin.protocol)://\(message.frameInfo.securityOrigin.host) ")
    }
    if d["type"] as? String == "final" { onFinal(d["r"] as! [String: Any]) }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var keep: [AnyObject] = []

func run(label: String, csp: String, then next: @escaping () -> Void) {
  let bridge = Bridge(label: label)
  let cfg = WKWebViewConfiguration()
  cfg.websiteDataStore = .nonPersistent()
  cfg.setURLSchemeHandler(SchemeHandler(csp: csp), forURLScheme: "agentos")
  cfg.mediaTypesRequiringUserActionForPlayback = []
  cfg.userContentController.add(bridge, name: "bridge")
  let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
  let wv = WKWebView(frame: win.contentView!.bounds, configuration: cfg)
  wv.navigationDelegate = bridge
  win.contentView!.addSubview(wv); win.orderFront(nil)
  keep += [bridge, wv, win]
  var reloads = 0
  bridge.onFinal = { r in
    if reloads > 0 { return }
    let data = try! JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])
    print("=== [\(label)] ===\n" + String(data: data, encoding: .utf8)!)
    // snapshot of WebGL canvas
    let sc = WKSnapshotConfiguration(); sc.rect = CGRect(x: 0, y: 0, width: 50, height: 50)
    wv.takeSnapshot(with: sc) { img, err in
      if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let c = rep.colorAt(x: 10, y: 10) {
        print("[\(label)] takeSnapshot pixel(10,10) r=\(String(format: "%.2f", c.redComponent)) g=\(String(format: "%.2f", c.greenComponent)) b=\(String(format: "%.2f", c.blueComponent))")
      } else { print("[\(label)] snapshot err \(String(describing: err))") }
      // reload latency
      reloads = 1; bridge.t = Date()
      bridge.onFinish = { print("[\(label)] reload -> didFinish \(Int(Date().timeIntervalSince(bridge.t)*1000)) ms"); bridge.onFinish = {}; win.orderOut(nil); next() }
      wv.reload()
    }
  }
  wv.load(URLRequest(url: URL(string: "agentos://app/index.html")!))
}
let strict = "default-src 'none'; script-src agentos: 'unsafe-inline' 'unsafe-eval' blob:; style-src 'unsafe-inline' agentos:; img-src agentos: data: blob:; connect-src agentos: blob: data:; frame-src agentos: about: data:; media-src agentos: blob: data:; worker-src blob: agentos:"
run(label: "no-CSP", csp: "") {
  run(label: "strict-CSP", csp: strict) { print("done"); exit(0) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { print("timeout"); exit(1) }
app.run()
