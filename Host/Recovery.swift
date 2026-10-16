import AgentOSCore
import AgentOSRuntime
import AppKit
import SwiftUI

@MainActor final class HostLifecycle: NSObject, NSApplicationDelegate {
  static weak var model: AppModel?
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationWillTerminate(_ notification: Notification) { Self.model?.recordCleanExit() }
}
extension AppModel {
  func checkShellHealth() async {
    guard !background, !safeMode, selected == nil, let id = shellAppID, let view = currentView,
      Date().timeIntervalSince(lastShellHealthCheck) >= 30
    else { return }
    lastShellHealthCheck = Date()
    do {
      _ = try await bounded(seconds: 5) {
        try await view.invoke(kind: "state", name: "", args: [:])
      }
    } catch {
      if shellAppID == id, selected == nil {
        await fallbackShell("桌面未响应：" + error.localizedDescription)
      }
    }
  }
  func bootRecoveryState() {
    let file = root.appendingPathComponent("system/boot.json")
    let previous = (try? Value.parse(String(contentsOf: file, encoding: .utf8))) ?? [:]
    let failures = previous["clean"] == false ? (previous["failures"]?.int ?? 0) + 1 : 0
    safeMode =
      failures >= 2 || NSEvent.modifierFlags.contains(.option)
      || ProcessInfo.processInfo.environment["AGENTOS_SAFE_MODE"] == "1"
    let marker: Value = ["clean": false, "failures": .number(Double(failures))]
    try? marker.encoded().write(to: file, options: .atomic)
    HostLifecycle.model = self
  }
  func recordCleanExit() {
    let marker: Value = ["clean": true, "failures": 0]
    try? marker.encoded().write(
      to: root.appendingPathComponent("system/boot.json"), options: .atomic)
  }
  func selectShell(_ id: String?) async {
    do {
      if let id {
        let app = try await kernel.app(id)
        guard app.version != "draft", app.manifest["runtime"]?["kind"] == "web" else {
          throw HostError("invalid_args", "桌面外壳必须是通过测试的 Web 应用")
        }
        guard
          await confirm(
            "将这个应用设为桌面外壳？它可以列出和打开应用、读取通知及活动摘要。系统确认框、设置和恢复仍由宿主绘制。", ["app": .string(app.title)])
        else { return }
        let view = try await runtime.instance(id, core: false)
        _ = try await bounded(seconds: 5) {
          try await view.invoke(kind: "state", name: "", args: [:])
        }
      }
      try await kernel.setHostSetting("shell.app", value: id)
      shellAppID = id
      home()
    } catch { self.error = error.localizedDescription }
  }
  func loadShell() async {
    guard !safeMode, selected == nil, let id = shellAppID else { return }
    do {
      let view = try await runtime.instance(id, core: false)
      if selected == nil {
        currentView = view
        status = "自定义桌面"
      }
    } catch { await fallbackShell(error.localizedDescription) }
  }
  func fallbackShell(_ reason: String) async {
    if let shellAppID { runtime.closeUI(shellAppID) }
    shellAppID = nil
    currentView = nil
    try? await kernel.setHostSetting("shell.app", value: nil)
    _ = try? await kernel.addNotification(
      title: "已恢复系统启动台", body: reason, context: RequestContext(.service("shell")))
    status = "已恢复系统启动台"
  }
  func shellRequest(_ name: String, args: Value, context: RequestContext) async throws -> Value {
    let origin = try await kernel.initiator(of: context)
    guard !safeMode, origin.appID == shellAppID, shellAppID != nil else {
      throw HostError("denied", "只有用户选择的桌面外壳可以使用此接口")
    }
    switch name {
    case "shell.apps":
      return .array(
        apps.map { ["id": .string($0.id), "title": .string($0.title), "icon": .string($0.icon)] })
    case "shell.open":
      let id = try args.requiredString("app")
      _ = try await kernel.app(id)
      Task { await self.open(id) }
      return ["opened": true]
    case "shell.notifications":
      try await kernel.propagate(Labels(isPrivate: true), to: context)
      return try await kernel.notifications()
    case "shell.activity":
      try await kernel.propagate(Labels(isPrivate: true), to: context)
      return .array(
        try await kernel.activities().prefix(30).map {
          ["action": .string($0.action), "state": .string($0.state), "at": .string($0.at)]
        })
    default: throw HostError("not_found", "未知外壳接口")
    }
  }
}

struct RecoveryPanel: View {
  @Bindable var model: AppModel
  @State private var selected = ""
  @State private var versions: [String] = []
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("恢复模式").font(.title2)
      Text("自动化和生成桌面已暂停。可以导出数据、回滚应用，再返回系统启动台。")
      Picker("应用", selection: $selected) {
        Text("选择应用").tag("")
        ForEach(model.apps) { Text($0.title).tag($0.id) }
      }
      .onChange(of: selected) { _, value in
        Task { versions = (try? await model.kernel.versions(value)) ?? [] }
      }
      List(versions, id: \.self) { version in
        HStack {
          Text(version)
          Spacer()
          Button("回滚代码") {
            Task {
              do {
                try await model.kernel.rollback(
                  selected, version: version, context: RequestContext(.user))
                model.runtime.reload(selected)
                await model.refresh()
              } catch { model.error = error.localizedDescription }
            }
          }
        }
      }
      HStack {
        Button("导出数据…") { model.exportData() }
        Button("打开数据目录") { NSWorkspace.shared.open(model.root) }
        Spacer()
        Button("使用系统启动台继续") {
          Task {
            await model.fallbackShell("从恢复模式启动")
            model.safeMode = false
            model.home()
          }
        }.buttonStyle(.borderedProminent)
      }
    }.padding(24).frame(width: 700, height: 460)
  }
}
