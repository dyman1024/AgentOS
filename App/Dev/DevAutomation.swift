import AppKit

/// Development hooks for driving the app without the UI.
///
///   --selftest-runtime <file.html>   load an HTML file as a temporary app, run a smoke test, print JSON, quit
///   AGENTOS_AUTOPROMPT="做个贪吃蛇"   send this prompt to a new app at launch
///   AGENTOS_AUTOQUIT=1               quit after the auto prompt finishes
///
/// Results and screenshots are written to the logs folder.
enum DevAutomation {
    static func runIfRequested(_ model: AppModel) async {
        let args = CommandLine.arguments
        let env = ProcessInfo.processInfo.environment
        guard args.contains("--selftest-runtime") || env["AGENTOS_AUTOPROMPT"] != nil else { return }
        // Launched from a terminal the window may open behind other windows, and WebKit pauses
        // rendering for covered windows. Bring it to the front so the runtime actually runs.
        NSApp.activate()
        NSApp.windows.first { $0.isVisible }?.orderFrontRegardless()

        if let i = args.firstIndex(of: "--selftest-runtime"), i + 1 < args.count {
            await selfTestRuntime(model, html: URL(fileURLWithPath: args[i + 1]))
            NSApp.terminate(nil)
            return
        }
        if let prompt = env["AGENTOS_AUTOPROMPT"], !prompt.isEmpty {
            try? await Task.sleep(for: .seconds(1))
            model.showLauncher()
            await model.send(prompt)
            if let id = model.currentAppId { await saveScreenshot(model, appId: id, name: "autoprompt") }
            if env["AGENTOS_AUTOQUIT"] == "1" { NSApp.terminate(nil) }
        }
    }

    private static func selfTestRuntime(_ model: AppModel, html: URL) async {
        let manifest = model.registry.create()
        model.registry.update(manifest.id) { $0.title = "selftest: \(html.lastPathComponent)"; $0.icon = "🧪" }
        try? FileManager.default.copyItem(at: html, to: Paths.appDir(manifest.id).appendingPathComponent("index.html"))
        model.open(manifest.id)
        try? await Task.sleep(for: .seconds(1))  // let SwiftUI put the web view into the window

        let controller = model.runtime.controller(for: manifest.id)
        let run = await controller.runApp()
        let smoke = await controller.smokeTest([
            "inputs": [
                ["action": "press", "key": " "],
                ["action": "wait", "ms": 300],
                ["action": "press", "key": "ArrowUp"],
                ["action": "wait", "ms": 300],
                ["action": "press", "key": "ArrowLeft"],
            ],
        ])
        let shot = await saveScreenshot(model, appId: manifest.id, name: "selftest")
        let report: JSON = ["appId": .string(manifest.id), "run_app": run, "smoke_test": smoke, "screenshot": shot.map(JSON.string) ?? .null]
        let out = Paths.logs.appendingPathComponent("selftest-result.json")
        try? report.data(pretty: true).write(to: out)
        Log.event("selftest_done", ["result": .string(out.path)])
        if ProcessInfo.processInfo.environment["AGENTOS_SELFTEST_KEEP"] != "1" { model.delete(manifest.id) }
    }

    @discardableResult
    private static func saveScreenshot(_ model: AppModel, appId: String, name: String) async -> String? {
        guard let shot = try? await model.runtime.controller(for: appId).screenshot(maxPixels: 1600),
              let b64 = shot["pngBase64"]?.string, let data = Data(base64Encoded: b64) else { return nil }
        let url = Paths.logs.appendingPathComponent("\(name)-\(appId.prefix(8)).png")
        try? data.write(to: url)
        return url.path
    }
}
