import AgentOSCore
import Foundation

@MainActor private final class Race {
  var continuation: CheckedContinuation<Value, Error>?
  func finish(_ result: Result<Value, Error>) {
    guard let c = continuation else { return }
    continuation = nil
    c.resume(with: result)
  }
}
@MainActor public func bounded(
  seconds: Double, operation: @escaping @MainActor () async throws -> Value
) async throws -> Value {
  let race = Race()
  return try await withCheckedThrowingContinuation { continuation in
    race.continuation = continuation
    Task { @MainActor in
      do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
    }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(seconds))
      race.finish(.failure(HostError("timeout", "Application exceeded its deadline")))
    }
  }
}
@MainActor public final class RuntimeCoordinator {
  public let kernel: Kernel
  public var service: ((String, Value, RequestContext) async throws -> Value)?
  public var confirm: ((String, Value) async -> Bool)?
  public var backends: AppBackendRuntime?
  public var externalTools: (() -> [Value])?
  public private(set) var cores: [String: any CoreHost] = [:]
  public private(set) var interfaces: [String: WebInstance] = [:]
  private var nativeUIs: [String: NativeInstance] = [:]
  private var nativeBinaries: [String: URL] = [:]
  private var candidates: [String: (InstalledApp, URL)] = [:]
  private var busy: Set<String> = []
  private var updating: Set<String> = []
  private var pumping = false
  public var hasActiveWork: Bool {
    !busy.isEmpty || !automationTasks.isEmpty || pumping || backends?.hasActiveWork == true
  }
  var automationTasks: [String: Task<Void, Never>] = [:]
  private let lifetime = UUID().uuidString
  public init(kernel: Kernel) { self.kernel = kernel }
  public func closeAll() {
    for task in automationTasks.values { task.cancel() }
    automationTasks = [:]
    for instance in cores.values { instance.close() }
    for instance in interfaces.values { instance.close() }
    for instance in nativeUIs.values { instance.close() }
    nativeUIs = [:]
    cores = [:]
    interfaces = [:]
  }
  public func closeUI(_ id: String) {
    interfaces.removeValue(forKey: id)?.close()
    nativeUIs.removeValue(forKey: id)?.close()
  }
  public func reload(_ id: String) {
    nativeUIs.removeValue(forKey: id)?.close()
    cores.removeValue(forKey: id)?.close()
    interfaces.removeValue(forKey: id)?.close()
  }
  private func resolve(_ name: String) async throws -> InstalledApp {
    if let item = candidates.values.first(where: { $0.0.id == name || $0.0.namespace == name }) {
      return item.0
    }
    return try await kernel.app(name)
  }
  public func instance(_ id: String, core: Bool) async throws -> WebInstance {
    let item = try await resolve(id)
    if let existing = (core ? cores[item.id] : interfaces[item.id]) as? WebInstance,
      !existing.invalidated,
      existing.app.version == item.version
    {
      return existing
    }
    if core, cores.count >= 8,
      let idle = cores.values.filter({ !busy.contains($0.app.id) && interfaces[$0.app.id] == nil })
        .min(by: { $0.lastUsed < $1.lastUsed })
    {
      cores.removeValue(forKey: idle.app.id)?.close()
    }
    if core, cores.count >= 8 { throw HostError("unavailable", "All eight core slots are busy") }
    let directory: URL
    if let candidate = candidates[item.id] {
      directory = candidate.1
    } else {
      directory = try await kernel.activeDirectory(item.id)
    }
    let instance = try await WebInstance(
      app: item, directory: directory, isCore: core, temporary: candidates[item.id] != nil,
      instanceID: "\(lifetime)/\(item.id)/\(core ? "core" : "ui")")
    let principal: Principal = core ? .core(item.id) : .ui(item.id)
    instance.onRequest = { [weak self] method, args, context in
      guard let self else { throw HostError("unavailable", "Host stopped") }
      return try await self.route(method, args: args, context: context)
    }
    instance.onSubscription = { [weak self, weak instance] pattern in
      guard let self, let instance else { throw HostError("unavailable", "Core stopped") }
      let context = RequestContext(.core(item.id), instanceID: instance.instanceID)
      let id = "\(item.id):\(Kernel.digest(Data(pattern.utf8)))"
      _ = try await self.kernel.subscribe(id: id, pattern: pattern, context: context)
    }
    try await kernel.bindInstance(instance.instanceID, principal: principal)
    try await kernel.propagate(
      kernel.packageLabels(item.id), to: RequestContext(principal, instanceID: instance.instanceID))
    if !core { instance.context = RequestContext(principal, instanceID: instance.instanceID) }
    if core { cores[item.id] = instance } else { interfaces[item.id] = instance }
    do {
      try await instance.ready()
      return instance
    } catch {
      instance.close()
      if core { cores[item.id] = nil } else { interfaces[item.id] = nil }
      throw error
    }
  }
  private func native(_ item: InstalledApp, core: Bool) async throws -> NativeInstance {
    let directory: URL
    if let candidate = candidates[item.id] {
      directory = candidate.1
    } else {
      directory = try await kernel.activeDirectory(item.id)
    }
    let kernelRoot = await kernel.root
    let digest = try Kernel.treeDigest(directory)
    let key = item.id + "/" + digest
    let executable: URL
    if let cached = nativeBinaries[key] {
      executable = cached
    } else {
      let output = kernelRoot.appendingPathComponent("system/native-builds/" + UUID().uuidString)
      executable = try await NativeSandbox.build(source: directory, output: output)
      nativeBinaries[key] = executable
    }
    let target = NativeInstance(
      app: item, executable: executable,
      storage: kernelRoot.appendingPathComponent(
        "system/appdata/" + item.id + (core ? "/core" : "/ui")), isCore: core,
      instanceID: "\(lifetime)/\(item.id)/native-\(core ? "core" : "ui")")
    let principal: Principal = core ? .core(item.id) : .ui(item.id)
    try await kernel.bindInstance(target.instanceID, principal: principal)
    try await kernel.propagate(
      kernel.packageLabels(item.id), to: RequestContext(principal, instanceID: target.instanceID))
    if !core { target.context = RequestContext(principal, instanceID: target.instanceID) }
    target.onRequest = { [weak self] method, args, context in
      guard let self else { throw HostError("unavailable", "Host stopped") }
      return try await route(method, args: args, context: context)
    }
    target.onSubscription = { [weak self, weak target] pattern in
      guard let self, let target else { throw HostError("unavailable", "Core stopped") }
      let context = RequestContext(.core(item.id), instanceID: target.instanceID)
      _ = try await kernel.subscribe(
        id: "\(item.id):\(Kernel.digest(Data(pattern.utf8)))", pattern: pattern, context: context)
    }
    do {
      try await target.ready()
      return target
    } catch {
      target.close()
      throw error
    }
  }
  public func coreInstance(_ id: String) async throws -> any CoreHost {
    let item = try await resolve(id)
    if let target = cores[item.id], !target.invalidated, target.app.version == item.version {
      return target
    }
    guard item.manifest["runtime"]?["kind"] == "macos-native" else {
      return try await instance(id, core: true)
    }
    guard cores.count < 8 else { throw HostError("unavailable", "All core slots are occupied") }
    let target = try await native(item, core: true)
    cores[item.id] = target
    return target
  }
  public func openNativeUI(_ id: String) async throws {
    let item = try await resolve(id)
    if let target = nativeUIs[item.id], !target.invalidated { return }
    nativeUIs[item.id] = try await native(item, core: false)
  }
  public func route(_ method: String, args: Value, context: RequestContext) async throws -> Value {
    if let id = context.principal.appID, updating.contains(id) {
      throw HostError("conflict", "Application update is committing")
    }
    switch method {
    case "backend.call":
      guard let id = context.principal.appID, case .core = context.principal, let backends else {
        throw HostError(
          "unavailable", "Only an application core with an installed workbench can call its backend"
        )
      }
      try await kernel.authorize(context, capability: "service", scope: "backend.call")
      try await kernel.consumeQuota("backend.call", limit: 1000, context: context)
      let app = try await resolve(id)
      let directory: URL
      if let candidate = candidates[id] {
        directory = candidate.1
      } else {
        directory = try await kernel.activeDirectory(id)
      }
      try await kernel.propagate(Labels(taint: ["backend:" + id], isPrivate: true), to: context)
      let ticket = try await kernel.prepareSink(
        action: "backend.call", args: args, effect: .write,
        capability: "service", scope: "backend.call", context: context)
      _ = try await kernel.claimSink(ticket.id, context: context)
      do {
        let result = try await backends.call(
          app: app, directory: directory, method: args.requiredString("method"),
          args: args["args"] ?? [:])
        try await kernel.finishSink(ticket.id, state: "done", result: result)
        try await kernel.validateContext(context)
        return result
      } catch {
        try? await kernel.finishSink(
          ticket.id, state: "unknown", result: ["message": .string(error.localizedDescription)])
        throw error
      }
    case "data.restoreGroup":
      let change = try await kernel.prepareGroupRecovery(args, context: context)
      guard change.summary["canApply"] == true else {
        throw HostError("conflict", "Recovery is empty or has conflicts", details: change.summary)
      }
      guard try await kernel.initiator(of: context) != .service("cli"),
        await confirm?("恢复所选应用或运行的数据写入", change.summary) == true
      else {
        throw HostError(
          "needs_confirmation", "Group recovery requires host confirmation", details: change.summary
        )
      }
      return try await kernel.applyGroupRecovery(change, approved: true, context: context)
    case "data.migrate":
      let change = try await kernel.prepareMigration(args, context: context)
      guard try await kernel.initiator(of: context) != .service("cli"),
        await confirm?("迁移共享集合：先备份，再原子提交", change.summary) == true
      else {
        throw HostError(
          "needs_confirmation", "Migration requires host confirmation", details: change.summary)
      }
      return try await kernel.applyDataChange(change, approved: true, context: context)
    case "apps.search":
      let local = try await kernel.route(method, args: args, context: context).array ?? []
      let query = (args["query"]?.string ?? "").lowercased()
      let external = (externalTools?() ?? []).filter {
        query.isEmpty
          || (($0["name"]?.string ?? "") + " " + ($0["description"]?.string ?? "")).lowercased()
            .contains(query)
      }
      if !external.isEmpty {
        try await kernel.propagate(Labels(taint: ["mcp:catalog"]), to: context)
      }
      return .array(Array((local + external).prefix(min(max(args["limit"]?.int ?? 20, 1), 100))))
    case "apps.describe" where args["tool"]?.string?.hasPrefix("ext.") == true:
      try await kernel.authorize(context, capability: "apps.discover", scope: "*")
      guard let tool = externalTools?().first(where: { $0["name"] == args["tool"] }) else {
        throw HostError("not_found", "MCP tool is not connected")
      }
      try await kernel.propagate(Labels(taint: ["mcp:catalog"]), to: context)
      return tool
    case "automation.list":
      try await kernel.authorize(context, capability: "automation.read", scope: "*")
      return try await kernel.automations()
    case "automation.create":
      do {
        return ["id": .string(try await kernel.createAutomation(args, context: context))]
      } catch let e as HostError where e.code == "needs_confirmation" {
        guard context.principal != .service("cli") else { throw e }
        guard await confirm?("创建会影响外部服务的自动化", args) == true else {
          throw HostError("denied", "Plan was not approved")
        }
        return [
          "id": .string(try await kernel.createAutomation(args, approved: true, context: context))
        ]
      }
    case "automation.pause", "automation.resume":
      do {
        try await kernel.setAutomation(
          args.requiredString("id"), enabled: method == "automation.resume", context: context)
      } catch let error as HostError where error.code == "needs_confirmation" {
        guard try await kernel.initiator(of: context) != .service("cli"),
          await confirm?(error.message, error.details) == true
        else { throw error }
        try await kernel.setAutomation(
          args.requiredString("id"), enabled: true, approved: true, context: context)
      }
      return ["ok": true]
    case "events.emit":
      return try await kernel.emit(
        args.requiredString("type"), data: args["data"] ?? [:], context: context)
    case "self.call":
      guard let id = context.principal.appID else {
        throw HostError("denied", "Self is only available to applications")
      }
      if case .ui = context.principal {
        try await kernel.authorize(context, capability: "self.call", scope: id)
      }
      let app = try await resolve(id)
      return try await call(
        app.namespace + "." + args.requiredString("name"), args: args["args"] ?? [:],
        caller: context, selfCall: true)
    case "apps.call":
      return try await call(args.requiredString("tool"), args: args["args"] ?? [:], caller: context)
    case "apps.commit": return try await commit(args.requiredString("app"), context: context)
    case "apps.commitGroup":
      guard let ids = args["apps"]?.array, ids.allSatisfy({ $0.string != nil }) else {
        throw HostError("invalid_args", "Provide an apps array")
      }
      return try await commitGroup(ids.compactMap(\.string), context: context)
    case "runtime.inspect":
      let id = try args.requiredString("app")
      try await kernel.authorize(context, capability: "app.read", scope: id)
      let instance = try await instance(id, core: false)
      return [
        "console": .array(instance.console),
        "state": try await bounded(seconds: 5) {
          try await instance.invoke(kind: "state", name: "", args: [:])
        }, "text": try await instance.evaluate("return window.__aosHost.text()"),
      ]
    case "runtime.input":
      let id = try args.requiredString("app")
      try await kernel.authorize(context, capability: "app.edit", scope: id)
      let instance = try await instance(id, core: false)
      if let key = args["key"]?.string {
        _ = try await instance.evaluate(
          "window.__aosHost.key(key);return true", arguments: ["key": .string(key)])
      } else {
        _ = try await instance.evaluate(
          "window.__aosHost.click(x,y);return true",
          arguments: ["x": args["x"] ?? 0, "y": args["y"] ?? 0])
      }
      return ["ok": true]
    default:
      if ["data.", "apps.", "workspace.", "activity.", "events.list"].contains(
        where: method.hasPrefix)
      {
        return try await kernel.route(method, args: args, context: context)
      }
      guard let service else { throw HostError("unavailable", "System service is not connected") }
      return try await service(method, args, context)
    }
  }
  public func call(_ name: String, args: Value, caller: RequestContext, selfCall: Bool = false)
    async throws -> Value
  {
    if name.hasPrefix("ext."), let service { return try await service(name, args, caller) }
    let pieces = name.split(separator: ".", maxSplits: 1).map(String.init)
    guard pieces.count == 2 else { throw HostError("not_found", "Use namespace.tool") }
    let app = try await resolve(pieces[0])
    guard !updating.contains(app.id) else {
      throw HostError("conflict", "Application update is committing")
    }
    let definition = try AppInterface(app.interface)
    guard let tool = definition.tools.first(where: { $0.name == pieces[1] }) else {
      throw HostError("not_found", "Unknown tool")
    }
    if !selfCall {
      try await kernel.authorize(caller, capability: "call", scope: name)
    } else {
      guard caller.principal.appID == app.id else {
        throw HostError("denied", "Self target mismatch")
      }
    }
    guard caller.depth < 8 else { throw HostError("denied", "Call depth exceeded") }
    let refs = try await kernel.schemaReferences()
    try Schema.validate(args, against: tool.input, references: refs)
    if tool.interactive {
      guard caller.runID == nil else {
        throw HostError("denied", "Interactive tools require an explicit foreground UI action")
      }
      if app.manifest["runtime"]?["kind"] == "macos-native" {
        try await openNativeUI(app.id)
      } else {
        _ = try await instance(app.id, core: false)
      }
    }
    let target = try await coreInstance(app.id)
    let nested = selfCall && caller.instanceID == target.instanceID
    let until = Date().addingTimeInterval(30)
    while busy.contains(app.id) && !nested {
      guard caller.depth == 0, Date() < until else {
        throw HostError("unavailable", "Core is busy or a recursive call would deadlock")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    if !nested { busy.insert(app.id) }
    defer { if !nested { busy.remove(app.id) } }
    let ownRun = caller.runID == nil
    let runID: String
    if let run = caller.runID {
      runID = run
    } else {
      runID = try await kernel.startRun(
        session: "tool:" + UUID().uuidString, initiator: caller.principal, role: "tool",
        summary: name, duration: 30)
    }
    let context = RequestContext(
      .core(app.id), runID: runID, instanceID: target.instanceID, depth: caller.depth + 1)
    let previous = target.context
    target.context = context
    defer { target.context = previous }
    do {
      try await kernel.propagate(kernel.labels(for: caller), to: context)
      let result = try await bounded(seconds: 30) {
        try await target.invoke(kind: "tool", name: tool.name, args: args)
      }
      try await kernel.validateContext(context)
      let value = result["structuredContent"] ?? result
      try Schema.validate(value, against: tool.output, references: refs)
      try await kernel.propagate(kernel.labels(for: context), to: caller)
      if ownRun { try await kernel.finishRun(runID) }
      return value
    } catch {
      if (error as? HostError)?.code == "timeout" {
        target.close()
        cores[app.id] = nil
      }
      if ownRun { try? await kernel.finishRun(runID, status: "failed") }
      throw error
    }
  }
  public func pumpEvents() async {
    guard !pumping else { return }
    pumping = true
    defer { pumping = false }
    do {
      // Ensure durable subscriptions are registered even before the first UI opens.
      for app in try await kernel.installedApps() where app.version != "draft" {
        if !(try AppInterface(app.interface)).subscriptions.isEmpty {
          _ = try? await coreInstance(app.id)
        }
      }
      for row in try await kernel.subscriptions().array ?? [] {
        guard let holder = row["holder"]?.string, holder.hasPrefix("app:"),
          holder.hasSuffix("/core"), let id = row["id"]?.string,
          let pattern = row["pattern"]?.string
        else { continue }
        let appID = String(holder.dropFirst(4).dropLast(5))
        guard !busy.contains(appID) else { continue }
        let target: any CoreHost
        do { target = try await coreInstance(appID) } catch { continue }
        let base = RequestContext(.core(appID), instanceID: target.instanceID)
        guard let delivery = try? await kernel.nextDelivery(id, context: base) else { continue }
        let run = try await kernel.startRun(
          session: "event:" + delivery.event.id + ":" + appID, initiator: .core(appID),
          role: "event", summary: pattern, duration: 30)
        let context = RequestContext(
          .core(appID), runID: run, instanceID: target.instanceID, depth: delivery.event.depth + 1)
        busy.insert(appID)
        target.context = context
        do {
          try await kernel.propagate(delivery.event.labels, to: context)
          _ = try await bounded(seconds: 30) {
            try await target.invoke(kind: "event", name: pattern, args: Value.from(delivery.event))
          }
          try await kernel.acknowledge(id, sequence: delivery.sequence, context: context)
          try await kernel.finishRun(run)
        } catch {
          try? await kernel.failDelivery(
            id, sequence: delivery.sequence, error: error.localizedDescription, context: base)
          try? await kernel.finishRun(run, status: "failed")
          if (error as? HostError)?.code == "timeout" {
            target.close()
            cores[appID] = nil
          }
        }
        target.context = nil
        busy.remove(appID)
      }
      for (id, core) in cores
      where !busy.contains(id) && interfaces[id] == nil
        && Date().timeIntervalSince(core.lastUsed) > 300
      {
        core.close()
        cores[id] = nil
      }
    } catch {
      // Retry on the next host tick. Individual delivery failures are persisted by the bus.
    }
  }
  public func commit(_ id: String, context: RequestContext) async throws -> Value {
    let result = try await commitGroup([id], context: context)
    let item = result["apps"]!.array![0]
    return ["app": item["app"]!, "version": item["version"]!, "tests": result["tests"]!]
  }
  public func commitGroup(_ ids: [String], context: RequestContext) async throws -> Value {
    let packages = try await kernel.preparePackages(ids, context: context)
    defer { for package in packages { try? FileManager.default.removeItem(at: package.directory) } }
    var reports: [Value] = []
    for package in packages {
      let report = try await contractTests(package, participants: packages)
      guard report["pass"]?.bool == true else {
        throw HostError(
          "contract_failed", "Candidate failed isolated contract tests",
          details: ["app": .string(package.appID), "report": report])
      }
      reports.append(["app": .string(package.appID), "report": report])
    }
    var approved = false
    do {
      try await kernel.validatePackages(
        packages, testsPassed: true, approvedCapabilities: false, context: context)
    } catch let error as HostError where error.code == "needs_confirmation" {
      guard try await kernel.initiator(of: context) != .service("cli") else { throw error }
      guard
        await confirm?(
          "批准应用联合更新与数据变更",
          .array(
            packages.map {
              [
                "app": .string($0.appID), "fromVersion": .string($0.baseVersion),
                "manifest": $0.manifest, "interface": $0.interface.raw,
                "migration": $0.migration?.summary ?? .null,
                "interfaceChanges": .array($0.interfaceChanges.map(Value.string)),
              ]
            })) == true
      else { throw HostError("denied", "Update was not approved") }
      approved = true
    }
    let participants = Set(packages.map(\.appID))
    guard busy.isDisjoint(with: participants), updating.isDisjoint(with: participants) else {
      throw HostError("conflict", "An update participant is still executing; retry when idle")
    }
    updating.formUnion(participants)
    defer { updating.subtract(participants) }
    for id in participants { reload(id) }
    try await kernel.activatePackages(
      packages, testsPassed: true, approvedCapabilities: approved, context: context)
    return [
      "apps": .array(packages.map { ["app": .string($0.appID), "version": .string($0.version)] }),
      "tests": ["pass": true, "participants": .array(reports), "isolated": true],
    ]
  }
  public func contractTests(_ package: PreparedPackage) async throws -> Value {
    try await contractTests(package, participants: [package])
  }
  private func contractTests(_ package: PreparedPackage, participants: [PreparedPackage])
    async throws -> Value
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agentos-contract-" + UUID().uuidString)
    let testKernel = try Kernel(root: root)
    let runner = RuntimeCoordinator(kernel: testKernel)
    runner.backends = backends?.isolated(storage: root.appendingPathComponent("backend-tests"))
    defer {
      runner.closeAll()
      if ProcessInfo.processInfo.environment["AGENTOS_KEEP_TEST_ROOT"] != "1" {
        try? FileManager.default.removeItem(at: root)
      }
    }
    do {
      for participant in participants {
        try await configureContractCandidate(
          participant, participants: participants, kernel: testKernel, runner: runner)
      }
      let result = try await runContractSuite(package, kernel: testKernel, runner: runner)
      runner.closeAll()
      await runner.backends?.closeAll()
      try await testKernel.shutdown()
      return result
    } catch {
      runner.closeAll()
      await runner.backends?.closeAll()
      try? await testKernel.shutdown()
      throw error
    }
  }
  private func configureContractCandidate(
    _ package: PreparedPackage, participants: [PreparedPackage], kernel testKernel: Kernel,
    runner: RuntimeCoordinator
  ) async throws {
    let app = InstalledApp(
      id: package.appID, namespace: package.interface.namespace, version: package.version,
      manifest: package.manifest, interface: package.interface.raw)
    runner.candidates[app.id] = (app, package.directory)
    let migrations = participants.compactMap(\.migration)
    for schema in try await kernel.schemas().array ?? []
    where package.interface.data[schema["collection"]?.string ?? ""] != nil {
      let collection = schema["collection"]!.string!
      let migration = migrations.first { $0.collection == collection }
      let existing = try await testKernel.schemas().array ?? []
      if !existing.contains(where: { $0["collection"]?.string == collection }) {
        try await testKernel.registerSchema(
          collection: collection, type: schema["type"]!.string!,
          definition: try migration?.definition ?? Value.parse(schema["definition"]!.string!),
          isPrivate: schema["private"]?.int == 1,
          version: migration != nil
            ? (schema["version"]?.int ?? 1) + 1 : (schema["version"]?.int ?? 1),
          context: RequestContext(.user))
      }
    }
    for (collection, access) in package.interface.data {
      _ = try await testKernel.grant(
        holder: .core(app.id), capability: "data.read", scope: collection)
      if access == "rw" {
        _ = try await testKernel.grant(
          holder: .core(app.id), capability: "data.write", scope: collection)
      }
    }
    if package.manifest["permissions"]?["services"]?.array?.contains("backend.call") == true {
      _ = try await testKernel.grant(
        holder: .core(app.id), capability: "service", scope: "backend.call")
    }
    for name in package.interface.calls {
      _ = try await testKernel.grant(holder: .core(app.id), capability: "call", scope: name)
    }
    for pattern in package.interface.subscriptions {
      _ = try await testKernel.grant(holder: .core(app.id), capability: "subscribe", scope: pattern)
    }
  }
  private func runContractSuite(
    _ package: PreparedPackage, kernel testKernel: Kernel, runner: RuntimeCoordinator
  ) async throws -> Value {
    let app = runner.candidates[package.appID]!.0
    let tests =
      try Value.parse(
        String(
          contentsOf: SafePath.resolve("tests/contract.json", under: package.directory),
          encoding: .utf8)
      ).array ?? []
    guard !tests.isEmpty else {
      throw HostError("contract_failed", "Contract suite must contain tests")
    }
    var results: [Value] = []
    var saved: [String: Value] = [:]
    var covered: Set<String> = []
    for test in tests {
      let name = test["name"]?.string ?? "unnamed"
      let local = test["tool"]?.string ?? ""
      do {
        guard package.interface.tools.contains(where: { $0.name == local }),
          test["expect"] != nil || test["expectError"] != nil
        else {
          throw HostError("contract_failed", "Every test needs a declared tool and an assertion")
        }
        let args = Self.substitute(test["args"] ?? [:], values: saved)
        let value = try await runner.call(
          app.namespace + "." + local, args: args, caller: RequestContext(.user))
        guard test["expectError"] == nil, Self.contains(value, expected: test["expect"] ?? .null)
        else {
          throw HostError("contract_failed", "Result did not match assertion", details: value)
        }
        if let key = test["saveAs"]?.string { saved[key] = value }
        covered.insert(local)
        results.append(["name": .string(name), "pass": true])
      } catch {
        let pass =
          test["expectError"]?.string != nil
          && test["expectError"]?.string == (error as? HostError)?.code
        if pass { covered.insert(local) }
        results.append([
          "name": .string(name), "pass": .bool(pass), "error": .string(error.localizedDescription),
        ])
      }
    }
    let missing = Set(package.interface.tools.map(\.name)).subtracting(covered)
    return [
      "pass": .bool(missing.isEmpty && results.allSatisfy { $0["pass"]?.bool == true }),
      "results": .array(results), "uncoveredTools": .array(missing.sorted().map(Value.string)),
      "isolated": true,
    ]
  }
  public static func contains(_ actual: Value, expected: Value) -> Bool {
    if let object = expected.object {
      return object.allSatisfy { key, value in
        actual[key].map { contains($0, expected: value) } ?? false
      }
    }
    return actual == expected
  }
  static func substitute(_ value: Value, values: [String: Value]) -> Value {
    if let ref = value["$result"]?.string {
      let parts = ref.split(separator: ".").map(String.init)
      var result = values[parts.first ?? ""] ?? .null
      for part in parts.dropFirst() { result = result[part] ?? .null }
      return result
    }
    if let object = value.object {
      return .object(object.mapValues { substitute($0, values: values) })
    }
    if let array = value.array { return .array(array.map { substitute($0, values: values) }) }
    return value
  }
}
