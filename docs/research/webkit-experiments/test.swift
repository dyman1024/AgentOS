import AppKit
import WebKit

let html = #"""
<!doctype html><html><head><meta charset="utf-8">
<script type="importmap">{"imports":{"lib":"agentos://app/lib.js"}}</script>
</head><body><canvas id=c width=100 height=100></canvas>
<script type="module">
const r = {};
const t0 = performance.now();
r.ua = navigator.userAgent;
r.origin = location.origin;
r.isSecureContext = window.isSecureContext;
r.hasGPU = !!navigator.gpu;
try { const a = navigator.gpu ? await navigator.gpu.requestAdapter() : null; r.gpuAdapter = !!a; if (a) { const d = await a.requestDevice(); r.gpuDevice = !!d; } } catch(e) { r.gpuErr = String(e); }
r.webgl2 = !!document.createElement('canvas').getContext('webgl2');
r.cryptoSubtle = typeof crypto.subtle;
r.getGamepads = typeof navigator.getGamepads;
try { const ac = new AudioContext(); r.audioState = ac.state; } catch(e) { r.audioErr = String(e); }
try { const m = await import('./mod.js'); r.relImport = m.x; } catch(e) { r.relImportErr = String(e); }
try { const m = await import('lib'); r.importMap = m.y; } catch(e) { r.importMapErr = String(e); }
try { const u = URL.createObjectURL(new Blob(['export default 7'], {type:'text/javascript'})); const m = await import(u); r.blobImport = m.default; } catch(e) { r.blobImportErr = String(e); }
try { r.fetchSame = (await (await fetch('./mod.js')).text()).length; } catch(e) { r.fetchSameErr = String(e); }
try { await fetch('https://example.com/'); r.fetchExternal = 'allowed'; } catch(e) { r.fetchExternal = 'blocked: ' + e; }
try { localStorage.setItem('k','v'); r.localStorage = localStorage.getItem('k'); } catch(e) { r.localStorageErr = String(e); }
try { const req = indexedDB.open('t'); r.indexedDB = await new Promise((res,rej)=>{req.onsuccess=()=>res('ok');req.onerror=()=>rej(req.error)}); } catch(e) { r.indexedDBErr = String(e); }
try { r.evalAllowed = eval('1+1'); } catch(e) { r.evalErr = String(e); }
let frames = 0; const fs = performance.now();
await new Promise(res => { function f(){ frames++; if (performance.now()-fs < 1000) requestAnimationFrame(f); else res(); } requestAnimationFrame(f); });
r.rafPerSec = frames;
r.testMs = Math.round(performance.now() - t0);
console.log('hello from page'); 
setTimeout(() => { throw new Error('boom-uncaught'); }, 0);
const reply = await window.webkit.messageHandlers.bridge.postMessage({type:'results', r});
r.bridgeReply = reply;
window.webkit.messageHandlers.bridge.postMessage({type:'final', r});
</script></body></html>
"""#

final class SchemeHandler: NSObject, WKURLSchemeHandler {
  let csp: String
  init(csp: String) { self.csp = csp }
  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    let url = task.request.url!
    var body: Data; var mime = "text/html"
    switch url.path {
    case "/index.html": body = Data(html.utf8)
    case "/mod.js": body = Data("export const x = 42;".utf8); mime = "text/javascript"
    case "/lib.js": body = Data("export const y = 'map-ok';".utf8); mime = "text/javascript"
    default: task.didFailWithError(URLError(.fileDoesNotExist)); return
    }
    var headers = ["Content-Type": mime]
    if !csp.isEmpty { headers["Content-Security-Policy"] = csp }
    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
    task.didReceive(resp); task.didReceive(body); task.didFinish()
  }
  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class Bridge: NSObject, WKScriptMessageHandlerWithReply, WKScriptMessageHandler, WKNavigationDelegate {
  var start = Date()
  let label: String
  var onDone: () -> Void = {}
  init(label: String) { self.label = label }
  func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
    if let d = message.body as? [String: Any], d["type"] as? String == "results" { replyHandler("pong-from-swift", nil); return }
    replyHandler(nil, nil)
    if let d = message.body as? [String: Any], d["type"] as? String == "final" {
      let ms = Int(Date().timeIntervalSince(start)*1000)
      let data = try! JSONSerialization.data(withJSONObject: d["r"]!, options: [.prettyPrinted, .sortedKeys])
      print("=== [\(label)] results (wall \(ms) ms since webview create) ===")
      print(String(data: data, encoding: .utf8)!)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.onDone() }
    }
  }
  func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
    print("[\(label)] console/err:", message.body)
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    print("[\(label)] didFinish at \(Int(Date().timeIntervalSince(start)*1000)) ms")
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { print("didFail", error) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { print("didFailProvisional", error) }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { print("[\(label)] WebContent process terminated") }
}

let consoleHook = """
(() => {
  const post = (level, args) => { try { window.webkit.messageHandlers.log.postMessage({level, args: args.map(a => { try { return typeof a === 'string' ? a : JSON.stringify(a) } catch { return String(a) } })}) } catch {} };
  for (const l of ['log','warn','error','info']) { const o = console[l]; console[l] = (...a) => { post(l, a); o.apply(console, a); }; }
  window.addEventListener('error', e => post('uncaught', [e.message, e.filename + ':' + e.lineno]));
  window.addEventListener('unhandledrejection', e => post('unhandledrejection', [String(e.reason)]));
})();
"""

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var keep: [AnyObject] = []

func run(label: String, csp: String, store: WKWebsiteDataStore, then next: @escaping () -> Void) {
  let bridge = Bridge(label: label)
  let cfg = WKWebViewConfiguration()
  cfg.websiteDataStore = store
  cfg.setURLSchemeHandler(SchemeHandler(csp: csp), forURLScheme: "agentos")
  cfg.mediaTypesRequiringUserActionForPlayback = []
  cfg.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "bridge")
  cfg.userContentController.add(bridge, name: "log")
  cfg.userContentController.addUserScript(WKUserScript(source: consoleHook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
  let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
  bridge.start = Date()
  let wv = WKWebView(frame: win.contentView!.bounds, configuration: cfg)
  wv.isInspectable = true
  wv.navigationDelegate = bridge
  win.contentView!.addSubview(wv)
  win.orderFront(nil)
  keep += [bridge, wv, win]
  bridge.onDone = { win.orderOut(nil); next() }
  wv.load(URLRequest(url: URL(string: "agentos://app/index.html")!))
}

let restrictive = "default-src agentos: 'unsafe-inline' blob: data:; script-src agentos: 'unsafe-inline' 'unsafe-eval' blob:; connect-src agentos:; img-src agentos: data: blob:"
let idStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
run(label: "cold/no-CSP/default-store", csp: "", store: .default()) {
  run(label: "warm/strict-CSP/forIdentifier-store", csp: restrictive, store: idStore) {
    print("done"); exit(0)
  }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("timeout"); exit(1) }
app.run()
