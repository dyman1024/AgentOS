import AppKit
import SwiftUI
import WebKit
setvbuf(stdout, nil, _IONBF, 0)
let js = "const ac = new AudioContext(); const b = ac.state; await Promise.race([ac.resume(), new Promise(r=>setTimeout(r,800))]); return b + ' -> ' + ac.state + ' | mediaDefault'"
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
Task { @MainActor in
  let cfg = WKWebViewConfiguration()
  print("WKWebViewConfiguration default mediaTypesRequiringUserActionForPlayback rawValue:", cfg.mediaTypesRequiringUserActionForPlayback.rawValue)
  let wv = WKWebView(frame: .init(x: 0, y: 0, width: 100, height: 100), configuration: cfg)
  let win = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
  win.contentView!.addSubview(wv); win.orderFront(nil)
  wv.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://example.invalid/"))
  try? await Task.sleep(for: .seconds(1.5))
  print("WKWebView default:", (try? await wv.callAsyncJavaScript(js, contentWorld: .page)) ?? "nil")
  let page = WebPage()
  let win2 = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
  win2.contentView = NSHostingView(rootView: WebView(page)); win2.orderFront(nil)
  for try await _ in page.load(html: "<p>x</p>", baseURL: URL(string: "https://example.invalid/")!) {}
  print("WebPage default:", (try? await page.callJavaScript(js)) ?? "nil")
  exit(0)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("timeout"); exit(1) }
app.run()
