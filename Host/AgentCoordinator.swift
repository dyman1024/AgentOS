import AgentOSCore
import AgentOSRuntime
import Foundation

@MainActor final class AgentCoordinator {
  let kernel: Kernel, runtime: RuntimeCoordinator, settings: ModelSettings, root: URL
  let engine = EngineTransport()
  var onUpdate: ((String, Value) -> Void)?
  var onAppCreated: ((String) -> Void)?
  private var sessions: [String: String] = [:], runs: [String: RequestContext] = [:],
    restricted: Set<String> = []
  private var configuration = ""
  init(kernel: Kernel, runtime: RuntimeCoordinator, settings: ModelSettings, root: URL) {
    self.kernel = kernel
    self.runtime = runtime
    self.settings = settings
    self.root = root
    engine.onUpdate = { [weak self] value in
      guard let id = value["runId"]?.string else { return }
      self?.onUpdate?(id, value["update"] ?? [:])
    }
    engine.onRequest = { [weak self] method, args in
      guard let self else { throw HostError("unavailable", "Host stopped") }
      return try await self.handle(method, args: args)
    }
    if let data = try? Data(contentsOf: root.appendingPathComponent("system/agent-sessions.json")) {
      sessions = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
  }
  func run(
    _ text: String, role: String = "operator", app: String? = nil, parent: RequestContext? = nil,
    initialLabels: Labels = Labels(), budget: Double? = nil, onStart: ((String) -> Void)? = nil
  ) async throws -> Value {
    let fingerprint = settings.provider + "|" + settings.model
    if !engine.running || configuration != fingerprint {
      guard runs.isEmpty else { throw HostError("conflict", "请等当前运行结束后切换模型") }
      let working = root.appendingPathComponent("system/agent")
      try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
      try engine.start(root: working, environment: settings.environment())
      configuration = fingerprint
    }
    let origin: Principal
    if let parent { origin = try await kernel.initiator(of: parent) } else { origin = .user }
    let session = "\(origin.id):\(settings.provider):\(settings.model):\(role):\(app ?? "global")"
    let limit =
      try await parent.mapAsync { try await kernel.remainingBudget($0) } ?? settings.budget
    let allocated = min(budget ?? settings.budget, limit)
    guard allocated >= 0.001 else { throw HostError("budget_exceeded", "没有可分配给 Agent 的剩余预算") }
    let parentReservation = try await parent.mapAsync {
      try await kernel.reserveBudget(allocated, context: $0)
    }
    let id: String
    do {
      id = try await kernel.startRun(
        session: session, initiator: origin, role: role, summary: text,
        budget: allocated, duration: 1800)
    } catch {
      if let parentReservation { try? await kernel.settleBudget(parentReservation, actual: 0) }
      throw error
    }
    let context = RequestContext(.run(id), runID: id, depth: (parent?.depth ?? -1) + 1)
    if settings.restrictedModel { restricted.insert(id) }
    runs[id] = context
    let watchdog = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(1800)) } catch { return }
      guard let self, self.runs[id] != nil else { return }
      self.cancel(id)
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      if self.runs[id] != nil { self.engine.stop() }
    }
    onStart?(id)
    defer {
      watchdog.cancel()
      runs[id] = nil
      restricted.remove(id)
    }
    do {
      try await kernel.propagate(initialLabels, to: context)
      if parent == nil { try await kernel.rememberUserLinks(text, context: context) }
      if let parent { try await kernel.propagate(kernel.labels(for: parent), to: context) }
      if settings.restrictedModel, try await kernel.labels(for: context).isPrivate {
        throw HostError("denied", "实验性模型不能接收此会话中的私人数据；请使用新会话或受支持模型")
      }
      let modelBudget = allocated * (role == "builder" ? 0.85 : 0.25)
      let modelReservation = try await kernel.reserveBudget(modelBudget, context: context)
      var args: Value = [
        "runId": .string(id), "role": .string(role), "text": .string(text),
        "model": .string(settings.model),
        "cwd": .string(root.appendingPathComponent("system/agent").path),
        "maxBudgetUsd": .number(modelBudget),
      ]
      var object = args.object!
      object["appId"] = app.map(Value.string)
      object["sessionId"] = sessions[session].map(Value.string)
      if !settings.restrictedModel { object["effort"] = .string(settings.effort) }
      args = .object(object)
      let result = try await engine.request("session/prompt", args)
      if let sessionId = result["sessionId"]?.string {
        sessions[session] = sessionId
        try JSONEncoder().encode(sessions).write(
          to: root.appendingPathComponent("system/agent-sessions.json"), options: .atomic)
      }
      try await kernel.settleBudget(modelReservation, actual: result["costUsd"]?.number)
      try await kernel.finishRun(
        id,
        status: result["cancelled"]?.bool == true
          ? "cancelled" : result["isError"]?.bool == true ? "failed" : "done")
      let total = try await kernel.runCost(id)
      if let parentReservation { try await kernel.settleBudget(parentReservation, actual: total) }
      if let parent { try await kernel.propagate(kernel.labels(for: context), to: parent) }
      var output = result.object ?? [:]
      output["costUsd"] = .number(total)
      return .object(output)
    } catch {
      try? await kernel.finishRun(id, status: "failed")
      if let parentReservation {
        try? await kernel.settleBudget(parentReservation, actual: kernel.runCost(id))
      }
      if let parent { try? await kernel.propagate(kernel.labels(for: context), to: parent) }
      throw error
    }
  }
  func cancel(_ id: String) {
    engine.notify("session/cancel", ["runId": .string(id)])
    Task { try? await kernel.finishRun(id, status: "cancelled") }
  }
  func stop() { engine.stop() }
  private func handle(_ method: String, args: Value) async throws -> Value {
    guard method == "host/call", let id = args["runId"]?.string, let context = runs[id] else {
      throw HostError("denied", "Unknown engine run")
    }
    try await kernel.validateContext(context)
    let name = try args.requiredString("method")
    let params = args["args"] ?? [:]
    onUpdate?(id, ["kind": "host_call", "name": .string(name)])
    let result: Value
    if name == "agent.build" {
      guard !runs.values.contains(where: { $0.runID != id }) else {
        throw HostError("denied", "A Builder is already active")
      }
      result = try await run(
        params.requiredString("request"), role: "builder", app: params["app"]?.string,
        parent: context)
    } else {
      do { result = try await runtime.route(name, args: params, context: context) } catch {
        // Contract/compiler diagnostics can contain generated source and private fixture values.
        if let detail = (error as? HostError)?.details, detail != .null {
          try await kernel.propagate(
            Labels(taint: ["host:diagnostics"], isPrivate: true), to: context)
        }
        if restricted.contains(id), try await kernel.labels(for: context).isPrivate {
          throw HostError("denied", "私人诊断内容不能交付给实验性模型")
        }
        onUpdate?(
          id,
          [
            "kind": "host_error", "name": .string(name),
            "code": .string((error as? HostError)?.code ?? "failed"),
          ])
        throw error
      }
    }
    if name == "apps.create", let app = result["id"]?.string { onAppCreated?(app) }
    if restricted.contains(id), try await kernel.labels(for: context).isPrivate {
      throw HostError("denied", "私人数据不能交付给实验性模型")
    }
    onUpdate?(id, ["kind": "host_result", "name": .string(name), "result": result])
    return result
  }
}
extension Optional {
  func mapAsync<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
    switch self {
    case .none: return nil
    case .some(let v): return try await transform(v)
    }
  }
}
