import AgentOSCore
import AgentOSRuntime
import AppKit
import Foundation

@MainActor final class WorkbenchService {
  let kernel: Kernel, vm: WorkbenchVM, root: URL
  var route: ((String, Value, RequestContext) async throws -> Value)?
  private var active = false
  private var lastUse = Date()
  private var persistentServices = Set<String>()
  func idle() async {
    if !active, persistentServices.isEmpty, Date().timeIntervalSince(lastUse) > 300 {
      try? await vm.suspend()
    }
  }
  init(kernel: Kernel, root: URL) {
    self.kernel = kernel
    self.root = root
    vm = WorkbenchVM(directory: root.appendingPathComponent("system/workbench"))
  }
  func install() throws {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "选择 Linux 内核（arm64 Image）"
    guard panel.runModal() == .OK, let kernel = panel.url else { return }
    panel.message = "选择工作间 ext4 磁盘镜像"
    guard panel.runModal() == .OK, let disk = panel.url else { return }
    try vm.install(kernel: kernel, image: disk)
  }
  func downloadImage(manifestURL: String, publicKey: String, confirm: (String, Value) async -> Bool)
    async throws -> String
  {
    guard !active else { throw HostError("conflict", "工作间正在执行任务") }
    active = true
    defer { active = false }
    let destination = try await HTTPClient.resolve(manifestURL)
    let response = try await HTTPClient.send(destination, maximumBytes: 100000)
    guard response.status == 200 else { throw HostError("network_error", "镜像清单下载失败；不接受重定向") }
    let release = try WorkbenchImage(manifest: response.body, trustedPublicKey: publicKey)
    guard
      await confirm(
        "下载并安装已验证的工作间基础镜像",
        [
          "version": .string(release.version), "publisher": .string(release.fingerprint),
          "downloadMB": .number(Double(release.kernel.bytes + release.disk.bytes) / 1_000_000),
          "effect": "新临时工作间和新后端使用新镜像；已有磁盘与应用数据保留",
        ])
    else {
      throw HostError("denied", "已取消镜像安装")
    }
    let staging = root.appendingPathComponent("system/image-download-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: staging) }
    let kernelFile = staging.appendingPathComponent("kernel")
    let diskFile = staging.appendingPathComponent("disk.ext4")
    try await ImageDownload.artifact(release.kernel, to: kernelFile)
    try await ImageDownload.artifact(release.disk, to: diskFile)
    try await vm.installVerified(release, kernel: kernelFile, image: diskFile)
    try await kernel.setHostSetting("vm.imageFeed", value: manifestURL)
    try await kernel.setHostSetting("vm.publisherKey", value: publicKey)
    return "基础镜像 \(release.version) 已安装；已有工作间磁盘保留"
  }
  func call(_ name: String, args: Value, context: RequestContext) async throws -> Value {
    try await kernel.authorize(context, capability: "service", scope: name)
    let initiator = try await kernel.initiator(of: context)
    guard initiator == .user || initiator == .service("cli") else {
      throw HostError(
        "denied", "Raw workbench commands are available only to the user and their Agent")
    }
    if name == "vm.stats" { return vm.stats() }
    lastUse = Date()
    guard !active else { throw HostError("conflict", "工作间正在执行其他任务") }
    active = true
    defer { active = false }
    let labelContext = RequestContext(.service("workbench"), instanceID: "workbench:persistent")
    try await kernel.bindInstance("workbench:persistent", principal: .service("workbench"))
    try await kernel.propagate(
      kernel.labels(for: labelContext).union(Labels(taint: ["vm:workbench"])), to: context)
    let ephemeral = args["ephemeral"]?.bool ?? false
    guard !ephemeral || name == "vm.exec" else {
      throw HostError("invalid_args", "ephemeral is only supported by vm.exec")
    }
    let supported: Set<String> = [
      "vm.exec", "vm.fs.read", "vm.fs.write", "vm.fs.list", "vm.copyIn", "vm.copyOut",
      "vm.service.start", "vm.service.stop", "vm.service.status", "vm.snapshot", "vm.restore",
      "vm.stop",
    ]
    guard supported.contains(name) else {
      throw HostError("not_found", "Unknown workbench operation")
    }
    let budget = try await kernel.remainingBudget(context)
    guard budget >= 0.001 else {
      throw HostError("budget_exceeded", "No remaining workbench budget")
    }
    let target = ephemeral ? try vm.ephemeral() : vm
    let ticket: SinkTicket
    let child: String
    let reservation: String
    var preparedTicket: String?
    do {
      ticket = try await kernel.prepareSink(
        action: name, args: args, effect: .write, capability: "service", scope: name,
        context: context)
      preparedTicket = ticket.id
      _ = try await kernel.claimSink(ticket.id, context: context)
      reservation = try await kernel.reserveBudget(budget, context: context)
      do {
        child = try await kernel.startRun(
          session: "vm-command:" + UUID().uuidString, initiator: initiator, role: "vm",
          summary: name, budget: budget, duration: 150)
      } catch {
        try? await kernel.settleBudget(reservation, actual: 0)
        throw error
      }
    } catch {
      if let preparedTicket {
        try? await kernel.finishSink(
          preparedTicket, state: "failed", result: ["message": .string(error.localizedDescription)])
      }
      if ephemeral { try? await target.discard() }
      throw error
    }
    let commandContext = RequestContext(.run(child), runID: child, depth: context.depth + 1)
    target.onHostRequest = { [weak self] method, params in
      guard let self, let route = self.route else {
        throw HostError("unavailable", "Host routing stopped")
      }
      let allowed: Set<String> = [
        "net.fetch", "apps.search", "apps.describe", "apps.call", "data.get", "data.query",
        "data.put", "data.delete", "data.batch",
      ]
      guard allowed.contains(method) else {
        throw HostError("denied", "VM bridge method is not permitted")
      }
      try await self.kernel.validateContext(commandContext)
      return try await route(method, params, commandContext)
    }
    defer { target.onHostRequest = nil }
    do {
      try await kernel.propagate(kernel.labels(for: context), to: commandContext)
      let result: Value
      switch name {
      case "vm.exec": result = try await target.execute("exec", args: args)
      case "vm.fs.read", "vm.fs.write", "vm.fs.list":
        result = try await target.execute(String(name.dropFirst(3)), args: args)
      case "vm.copyIn":
        let content = try await kernel.readFile(args, context: commandContext)
        guard let bytes = Data(base64Encoded: content["base64"]?.string ?? ""),
          let text = String(data: bytes, encoding: .utf8), bytes.count <= 1_000_000
        else { throw HostError("invalid_args", "Workspace transfer accepts UTF-8 text up to 1 MB") }
        result = try await target.execute(
          "fs.write", args: ["path": .string(args.requiredString("vmPath")), "text": .string(text)])
      case "vm.copyOut":
        let content = try await target.execute(
          "fs.read", args: ["path": .string(args.requiredString("vmPath"))])
        guard let bytes = Data(base64Encoded: content["base64"]?.string ?? ""),
          let text = String(data: bytes, encoding: .utf8), bytes.count <= 1_000_000
        else { throw HostError("invalid_args", "Workspace transfer accepts UTF-8 text up to 1 MB") }
        var destination = args.object ?? [:]
        destination["text"] = .string(text)
        result = try await kernel.writeFile(.object(destination), context: commandContext)
      case "vm.service.start", "vm.service.stop", "vm.service.status":
        result = try await target.execute(String(name.dropFirst(3)), args: args)
        let service = try args.requiredString("name")
        if result["running"] == true {
          persistentServices.insert(service)
        } else {
          persistentServices.remove(service)
        }
      case "vm.snapshot":
        result = try await target.snapshot(args["id"]?.string ?? UUID().uuidString)
      case "vm.restore":
        try await target.restore(args.requiredString("id"), cold: args["cold"]?.bool ?? false)
        persistentServices.removeAll()
        result = ["restored": true]
      case "vm.stop":
        try await target.stop()
        persistentServices.removeAll()
        result = ["stopped": true]
      default: throw HostError("not_found", "Unknown workbench operation")
      }
      try await kernel.propagate(kernel.labels(for: commandContext), to: context)
      if ephemeral { try await target.discard() }
      try await kernel.finishRun(child)
      try await kernel.settleBudget(reservation, actual: kernel.runCost(child))
      if !ephemeral { try await kernel.propagate(kernel.labels(for: context), to: labelContext) }
      try await kernel.finishSink(ticket.id, state: "done", result: result)
      try await kernel.validateContext(context)
      return result
    } catch {
      if ephemeral { try? await target.discard() }
      try? await kernel.propagate(kernel.labels(for: commandContext), to: context)
      try? await kernel.finishRun(child, status: "failed")
      try? await kernel.settleBudget(reservation, actual: kernel.runCost(child))
      if !ephemeral { try? await kernel.propagate(kernel.labels(for: context), to: labelContext) }
      try? await kernel.finishSink(
        ticket.id, state: "unknown", result: ["message": .string(error.localizedDescription)])
      throw error
    }
  }
}
