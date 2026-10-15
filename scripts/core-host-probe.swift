import AppKit
import WebKit
import Darwin

@MainActor final class Probe: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    var view: WKWebView!
    var timer: Timer?
    var started = Date()
    var samples: [Double] = []
    var failures: [String] = []
    var lastTicks = -1
    var webContentPeakRSSBytes = 0
    var webContentPID: Int32 = 0
    let duration = Double(ProcessInfo.processInfo.environment["PROBE_SECONDS"] ?? "3600") ?? 3600
    let output = ProcessInfo.processInfo.environment["PROBE_OUTPUT"] ?? "/tmp/agentos-core-probe.json"
    func applicationDidFinishLaunching(_ notification: Notification) {
        let c = WKWebViewConfiguration()
        c.preferences.inactiveSchedulingPolicy = .none
        c.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "probe")
        view = WKWebView(frame: .zero, configuration: c)
        view.navigationDelegate = self
        view.loadHTMLString("<script>window.ticks=0;setInterval(()=>ticks++,100);window.probe=async()=>{await new Promise(r=>setTimeout(r,10));return await webkit.messageHandlers.probe.postMessage({ticks})};</script>", baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sample() }
        }
        Task { await sample() }
    }
    func sample() async {
        let begin = Date()
        do {
            let value = try await view.callAsyncJavaScript("return await window.probe()", arguments: [:], in: nil, contentWorld: .page)
            samples.append(Date().timeIntervalSince(begin) * 1000)
            if let result = value as? [String: Any], let ticks = result["ticks"] as? Int,
               Date().timeIntervalSince(started) > 10 {
                if ticks <= lastTicks { failures.append("timer stopped progressing") }; lastTicks = ticks
            }
            if view.responds(to: NSSelectorFromString("_webProcessIdentifier")), let number = view.value(forKey:"_webProcessIdentifier") as? NSNumber {
                webContentPID = number.int32Value
                let p=Process(),pipe=Pipe();p.executableURL=URL(fileURLWithPath:"/bin/ps");p.arguments=["-o","rss=","-p",String(webContentPID)];p.standardOutput=pipe
                try p.run();let raw=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
                let rss=(Int(String(decoding:raw,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)) ?? 0)*1024
                webContentPeakRSSBytes=max(webContentPeakRSSBytes,rss)
            }
        } catch { failures.append(error.localizedDescription) }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed >= duration { finish() }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) { replyHandler(message.body, nil) }
    func finish() {
        timer?.invalidate()
        let sorted = samples.sorted(), p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count-1, Int(Double(sorted.count)*0.95))]
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let result: [String: Any] = ["durationSeconds": Date().timeIntervalSince(started), "samples": samples.count, "p95ms": p95, "failures": failures, "hostPeakRSSBytes": usage.ru_maxrss, "pass": failures.isEmpty && !samples.isEmpty && p95 < 200, "mode": "no window, inactiveSchedulingPolicy none", "memoryScope": "host getrusage peak and separately sampled WebContent RSS peak", "webContentPeakRSSBytes":webContentPeakRSSBytes, "webContentPID":webContentPID]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        print(String(data: try! JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
        NSApplication.shared.terminate(nil)
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = Probe()
    app.delegate = delegate
    app.run()
}
