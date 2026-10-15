import AgentOSCore
import AgentOSRuntime
import AppKit
import Observation
import SwiftUI

struct ChatLine: Codable, Identifiable {
  var id = UUID()
  var role: String
  var text: String
  var runID: String?
  var detail: String?
}
struct Approval: Identifiable {
  let id = UUID()
  let title: String
  let arguments: Value
  let complete: (Bool) -> Void
}
@MainActor @Observable final class AppModel {
  let root: URL, kernel: Kernel, runtime: RuntimeCoordinator, settings = ModelSettings()
  let lease: HostLease
  private var cli: CLIService?
  var agent: AgentCoordinator!
  var services: SystemServices!
  var notifications: [Value] = []
  var automationList: [Value] = []
  var showNotifications = false
  let background: Bool
  var shutdownRequested = false
  private var inFlightServices = 0
  var safeMode = false
  var shellAppID: String?
  var folderList: [Value] = []
  var browsers: [NativeBrowser] = []
  var apps: [InstalledApp] = []
  var activities: [Activity] = []
  var events: [Value] = []
  var grants: [Value] = []
  var exitRules: [Value] = []
  var runs: [Value] = []
  var selected: String?
  var tabs: [String] = []
  var currentView: WebInstance?
  var messages: [ChatLine] = []
  var input = ""
  var search = ""
  var role = "operator"
  var busy = false
  var activeRun: String?
  var error: String?
  var status = "就绪"
  var showSettings = false
  var showActivity = false
  var showVersions = false
  var showChat = true
  var approvals: [Approval] = []
  private var approvalPresenter: ApprovalPresenter?
  var mode: PermissionMode = .auto
  var versionList: [String] = []
  var windows: [String: NSWindow] = [:]
  private var timer: Task<Void, Never>?
  var lastShellHealthCheck = Date.distantPast
  init(background: Bool = false) throws {
    self.background = background
    root =
      ProcessInfo.processInfo.environment["AGENTOS_DATA_ROOT"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("AgentOS-Rebuild")
    lease =
      try background ? HostLease(root: root) : BackgroundHost.requestForegroundLease(root: root)
    try Data((background ? "background" : "foreground").utf8).write(
      to: root.appendingPathComponent("system/host-role"), options: .atomic)
    kernel = try Kernel(root: root)
    runtime = RuntimeCoordinator(kernel: kernel)
    runtime.backends = AppBackendRuntime(
      base: root.appendingPathComponent("system/workbench"),
      storage: root.appendingPathComponent("system/backends"))
    agent = AgentCoordinator(kernel: kernel, runtime: runtime, settings: settings, root: root)
    if let data = try? Data(contentsOf: root.appendingPathComponent("system/chat.json")) {
      messages = (try? JSONDecoder().decode([ChatLine].self, from: data)) ?? []
    }
    runtime.confirm = { [weak self] title, args in
      guard let self else { return false }
      return await self.confirm(title, args)
    }
    runtime.service = { [weak self] name, args, context in
      guard let self else { throw HostError("unavailable", "Host stopped") }
      return try await self.service(name, args: args, context: context)
    }
    services = SystemServices(kernel: kernel, settings: settings, root: root)
    runtime.externalTools = { [weak self] in self?.services.mcp.describe().array ?? [] }
    services.workbench.route = { [weak self] method, args, context in
      guard let self else { throw HostError("unavailable", "Host stopped") }
      return try await self.runtime.route(method, args: args, context: context)
    }
    services.confirm = { [weak self] title, args in await self?.confirm(title, args) ?? false }
    services.mcp.confirm = services.confirm
    services.browser = { [weak self] url in
      guard let self else { return }
      let browser = NativeBrowser(url: url) { [weak self] source, text in
        self?.send(
          "请处理我主动分享的网页。来源：" + source + "\n\n网页数据：\n" + text,
          labels: Labels(taint: ["browser:" + source], isPrivate: true))
      }
      self.browsers.append(browser)
      browser.show()
    }
    services.ask = { [weak self] task, context in
      guard let self else { throw HostError("unavailable", "Host stopped") }
      return try await self.agent.run(task, parent: context)
    }
    services.notify = { [weak self] title, body in
      self?.status = title
    }
    agent.onAppCreated = { [weak self] id in
      Task {
        await self?.refresh()
        await self?.open(id)
      }
    }
    agent.onUpdate = { [weak self] run, update in self?.receive(run, update) }
    cli = try CLIService(root: root) { [weak self] method, args, dry in
      guard let self else { throw HostError("unavailable", "Host stopped") }
      if method == "evaluation.run" { return try await self.evaluate(args) }
      if method == "evaluation.research" { return try await self.evaluateResearch(args) }
      if method == "system.releaseBackground" {
        guard self.background, !self.runtime.hasActiveWork, !self.busy, self.inFlightServices == 0
        else { throw HostError("conflict", "Host is foreground or completing work") }
        self.shutdownRequested = true
        return ["releasing": true]
      }
      let context = RequestContext(.service("cli"))
      if dry {
        if method == "apps.call" {
          let tool = try await self.runtime.route(
            "apps.describe", args: ["tool": args["tool"] ?? .null], context: context)
          try Schema.validate(
            args["args"] ?? [:], against: tool["input"] ?? .null,
            references: await self.kernel.schemaReferences())
        }
        return ["willExecute": false, "method": .string(method), "args": args]
      }
      let result = try await self.runtime.route(method, args: args, context: context)
      await self.refresh()
      return result
    }
    if !background {
      bootRecoveryState()
      Task {
        shellAppID = try? await kernel.hostSetting("shell.app")
        await loadShell()
      }
    }
    timer = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        if !self.safeMode {
          await self.runtime.pumpEvents()
          await self.runtime.pumpAutomations()
          self.services.mail.pump()
        }
        if self.selected == nil, self.shellAppID != nil, self.currentView?.invalidated == true {
          await self.fallbackShell("桌面运行时终止")
        }
        await self.checkShellHealth()
        await self.services.workbench.idle()
        await self.runtime.backends?.idle()
        await self.refresh()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }
  func shutdownBackground() async {
    timer?.cancel()
    timer = nil
    services.mail.stop()
    agent.stop()
    runtime.closeAll()
    try? await services.workbench.vm.stop()
    await runtime.backends?.closeAll()
    cli?.stop()
    cli = nil
    try? await kernel.shutdown()
    lease.release()
  }
  func refresh() async {
    do {
      apps = try await kernel.installedApps()
      activities = try await kernel.activities()
      grants = try await kernel.grants().array ?? []
      exitRules = try await kernel.rules().array ?? []
      events = try await kernel.events(limit: 1000).array ?? []
      runs = try await kernel.runs().array ?? []
      mode = try await kernel.mode()
      notifications = try await kernel.notifications().array ?? []
      automationList = try await kernel.automations().array ?? []
      folderList = try await kernel.folders(context: RequestContext(.user)).array ?? []
    } catch { self.error = error.localizedDescription }
  }
  func open(_ id: String) async {
    selected = id
    if !tabs.contains(id) { tabs.append(id) }
    do {
      let app = try await kernel.app(id)
      if app.version == "draft" {
        currentView = nil
        status = "正在构建 \(app.title)"
        return
      }
      if app.manifest["runtime"]?["kind"] == "macos-native" {
        try await runtime.openNativeUI(id)
        currentView = nil
        status = "原生应用已在独立窗口打开"
        return
      }
      currentView = try await runtime.instance(id, core: false)
      status = "就绪"
    } catch {
      currentView = nil
      self.error = error.localizedDescription
    }
  }
  func home() {
    selected = nil
    currentView = nil
    role = "operator"
    Task { await loadShell() }
  }
  func close(_ id: String) {
    tabs.removeAll { $0 == id }
    runtime.closeUI(id)
    windows.removeValue(forKey: id)?.close()
    if selected == id { home() }
  }
  func reload() {
    guard let selected else { return }
    runtime.reload(selected)
    Task { await open(selected) }
  }
  func popOut() {
    guard let selected, let currentView else { return }
    let window = NSWindow(
      contentRect: NSRect(x: 150, y: 150, width: 960, height: 700),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = apps.first { $0.id == selected }?.title ?? "AgentOS"
    window.contentView = currentView.webView
    window.makeKeyAndOrderFront(nil)
    windows[selected] = window
    self.currentView = nil
  }
  func send(_ suggested: String? = nil, labels: Labels = Labels()) {
    let text = (suggested ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !busy else { return }
    input = ""
    busy = true
    status = "思考中"
    messages.append(ChatLine(role: "user", text: text))
    messages.append(ChatLine(role: "assistant", text: ""))
    persist()
    let app = selected
    let role = self.role
    Task {
      do {
        let contextual = app.map { "当前应用：\($0)。\n" + text } ?? text
        let result = try await agent.run(
          contextual, role: role, app: role == "builder" ? app : nil, initialLabels: labels,
          onStart: { [weak self] id in
            self?.activeRun = id
            if let self, !self.messages.isEmpty {
              self.messages[self.messages.count - 1].runID = id
            }
          })
        if let index = messages.lastIndex(where: { $0.role == "assistant" }) {
          if messages[index].text.isEmpty {
            messages[index].text =
              result["text"]?.string ?? (result["cancelled"]?.bool == true ? "已取消。" : "运行结束。")
          }
          messages[index].detail = String(
            format: "%@ · $%.4f",
            result["cancelled"]?.bool == true
              ? "已取消" : result["isError"]?.bool == true ? "未完成" : "完成",
            result["costUsd"]?.number ?? 0)
        }
        status = "就绪"
      } catch {
        self.error = error.localizedDescription
        messages.append(ChatLine(role: "error", text: error.localizedDescription))
        status = "等待处理"
      }
      busy = false
      activeRun = nil
      persist()
      await refresh()
      if let selected, apps.first(where: { $0.id == selected })?.version != "draft" {
        await open(selected)
      }
    }
  }
  func cancel() {
    guard let activeRun else { return }
    agent.cancel(activeRun)
    status = "正在取消"
  }
  private func receive(_ run: String, _ update: Value) {
    if update["kind"] == "text_delta", let text = update["text"]?.string,
      let i = messages.lastIndex(where: { $0.role == "assistant" })
    {
      messages[i].text += text
    }
    if update["kind"] == "host_call" { status = update["name"]?.string ?? "执行中" }
    if update["kind"] == "host_result" { Task { await refresh() } }
  }
  func persist() {
    try? JSONEncoder().encode(messages).write(
      to: root.appendingPathComponent("system/chat.json"), options: .atomic)
  }
  func confirm(_ title: String, _ args: Value) async -> Bool {
    if background {
      _ = try? await kernel.addNotification(
        title: "需要确认：" + title, body: "请打开 AgentOS 查看活动，并重新执行该操作。",
        context: RequestContext(.service("background")))
      return false
    }
    return await withCheckedContinuation { c in
      approvals.append(
        Approval(title: title, arguments: args, complete: { c.resume(returning: $0) }))
      if approvalPresenter == nil { approvalPresenter = ApprovalPresenter(model: self) }
      approvalPresenter?.show()
    }
  }
  func approve(_ accepted: Bool) {
    guard !approvals.isEmpty else { return }
    let request = approvals.removeFirst()
    if approvals.isEmpty { approvalPresenter?.close() }
    request.complete(accepted)
  }
  func undo(_ activity: Activity) {
    Task {
      do {
        if activity.action == "calendar.create" {
          _ = try await services.call(
            "calendar.undo", args: ["effectID": .string(activity.id)],
            context: RequestContext(.user))
        } else if activity.action.hasPrefix("files.") {
          _ = try await kernel.undoFile(activity.id, context: RequestContext(.user))
        } else {
          _ = try await kernel.undo(activity.id, context: RequestContext(.user))
        }
        await refresh()
      } catch { self.error = error.localizedDescription }
    }
  }
  func revoke(_ id: String) {
    Task {
      do {
        try await kernel.revoke(id)
        await refresh()
      } catch { self.error = error.localizedDescription }
    }
  }
  func setMode(_ value: PermissionMode) {
    Task {
      do {
        try await kernel.setMode(value)
        mode = value
      } catch { self.error = error.localizedDescription }
    }
  }
  func versions() {
    guard let selected else { return }
    Task {
      do {
        versionList = try await kernel.versions(selected)
        showVersions = true
      } catch { self.error = error.localizedDescription }
    }
  }
  func rollback(_ version: String) {
    guard let selected else { return }
    Task {
      do {
        try await kernel.rollback(selected, version: version, context: RequestContext(.user))
        runtime.reload(selected)
        await refresh()
        await open(selected)
        showVersions = false
      } catch { self.error = error.localizedDescription }
    }
  }
  func remove(_ id: String) {
    Task {
      do {
        try await kernel.removeApp(id, context: RequestContext(.user))
        close(id)
        await refresh()
      } catch { self.error = error.localizedDescription }
    }
  }
  func exportData() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "AgentOS-data.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do { try await kernel.exportData().encoded().write(to: url, options: .atomic) } catch {
        self.error = error.localizedDescription
      }
    }
  }
  func authorizeFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "授权文件夹"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do {
        _ = try await kernel.addFolder(url)
        await refresh()
      } catch { self.error = error.localizedDescription }
    }
  }
  func importData() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do {
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= 100_000_000
        else { throw HostError("too_large", "数据文件超过 100 MB") }
        let archive = try Value.parse(String(contentsOf: url, encoding: .utf8))
        guard
          await confirm(
            "导入共享数据",
            [
              "records": .number(Double(archive["records"]?.array?.count ?? 0)),
              "note": "保留来源标签。遇到已有 ID 或 schema 冲突时整批拒绝，不覆盖当前数据。导入前自动备份。",
            ])
        else { return }
        _ = try await kernel.backupData()
        let result = try await kernel.importData(archive)
        status = "已导入 \(result["records"]?.int ?? 0) 条记录"
        await refresh()
      } catch { self.error = error.localizedDescription }
    }
  }
  func service(_ name: String, args: Value, context: RequestContext) async throws -> Value {
    guard !shutdownRequested else {
      throw HostError("unavailable", "Host is transferring its lease")
    }
    inFlightServices += 1
    defer { inFlightServices -= 1 }
    if name.hasPrefix("shell.") {
      return try await shellRequest(name, args: args, context: context)
    }
    return try await services.call(name, args: args, context: context)
  }
}
