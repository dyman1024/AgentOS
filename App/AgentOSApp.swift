import SwiftUI

@main
struct AgentOSApp: App {
    @State private var model = AppModel()

    init() {
        // The engine's stdin pipe may close underneath us; never let SIGPIPE kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        Window("AgentOS", id: "main") {
            ContentView()
                .environment(model)
                .task { await model.start() }
        }
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建应用") { model.showLauncher() }
                    .keyboardShortcut("n")
            }
            CommandMenu("应用") {
                Button("重新加载") { model.reloadCurrent() }
                    .keyboardShortcut("r")
                    .disabled(model.currentAppId == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HSplitView {
            RuntimePane()
                .frame(minWidth: 480, idealWidth: 860, maxWidth: .infinity, maxHeight: .infinity)
            ChatPane()
                .frame(minWidth: 340, idealWidth: 420, maxWidth: 680, maxHeight: .infinity)
        }
        .navigationTitle(model.currentApp.map { "\($0.icon) \($0.title)" } ?? "AgentOS")
        .toolbar { AppToolbar() }
        .alert("提示", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            SettingsLink { Text("打开设置") }
            Button("好", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
    }
}

struct AppToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.showLauncher() } label: { Label("启动台", systemImage: "square.grid.2x2") }
                .help("所有应用")
            Menu {
                ForEach(model.registry.apps) { app in
                    Button("\(app.icon) \(app.title)") { model.open(app.id) }
                }
            } label: {
                Label("切换应用", systemImage: "chevron.down")
            }
            .disabled(model.registry.apps.isEmpty)
            .help("切换应用")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.reloadCurrent() } label: { Label("重新加载", systemImage: "arrow.clockwise") }
                .disabled(model.currentAppId == nil)
                .help("重新加载应用 (⌘R)")
            SettingsLink { Label("设置", systemImage: "gearshape") }
                .help("设置")
        }
    }
}

struct RuntimePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let webView = model.currentWebView {
            RuntimeView(webView: webView)
        } else {
            LauncherView()
        }
    }
}
