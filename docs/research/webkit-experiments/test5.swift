import AppKit
import WebKit
final class D: NSObject, WKNavigationDelegate {
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) { print("didFinish") }
}
func webContentPIDs() -> [String] {
  let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "pid,%cpu,comm"]
  let pipe = Pipe(); p.standardOutput = pipe; try! p.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
  return String(data: data, encoding: .utf8)!.split(separator: "\n").filter { $0.contains("WebContent") }.map(String.init)
}
setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
var wv: WKWebView? = WKWebView(frame: .init(x: 0, y: 0, width: 100, height: 100))
let d = D(); wv!.navigationDelegate = d
let win = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
win.contentView!.addSubview(wv!); win.orderFront(nil)
wv!.loadHTMLString("<script>setTimeout(()=>{while(true){}}, 100)</script>", baseURL: nil)
var ticks = 0
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in ticks += 1 }
DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
  print("host main thread ticks during 3s with spinning page: \(ticks) (expect ~6)")
  print("WebContent procs (spinning):"); webContentPIDs().forEach { print("  ", $0) }
  let t = Date()
  wv!.evaluateJavaScript("1+1") { r, e in print("evaluateJavaScript returned after \(Int(Date().timeIntervalSince(t)*1000)) ms: \(String(describing: r)) \(String(describing: e))") }
  DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
    print("no reply within 2s -> navigating to a different origin, then tearing down web view")
    wv!.load(URLRequest(url: URL(string: "https://example.invalid/")!))
    wv!.removeFromSuperview(); wv = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
      print("WebContent procs 12s after teardown:"); webContentPIDs().forEach { print("  ", $0) }
      exit(0)
    }
  }
}
app.run()
