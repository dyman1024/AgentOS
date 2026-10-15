import Foundation

public struct AutomationJob: Sendable {
  public let id: String
  public let runID: String
  public let definition: Value
  public let event: Value?
  public let subscriptionID: String?
  public let eventSequence: Int?
}
extension Kernel {
  public func createAutomation(_ definition: Value, approved: Bool = false, context: RequestContext)
    throws -> String
  {
    try require(context, capability: "automation.create", scope: "*")
    let _ = try definition.requiredString("name")
    guard let steps = definition["steps"]?.array, !steps.isEmpty, steps.count <= 30 else {
      throw HostError("invalid_args", "A fixed plan needs 1–30 steps")
    }
    let trigger = definition["trigger"] ?? [:]
    guard (trigger["event"]?.string != nil) != (trigger["everySeconds"]?.number != nil) else {
      throw HostError("invalid_args", "Choose an event or interval trigger")
    }
    if let interval = trigger["everySeconds"]?.number {
      guard interval >= 60, interval <= 31_536_000 else {
        throw HostError("invalid_args", "Interval must be 60 seconds to one year")
      }
    }
    var external = false
    for step in steps {
      let name = try step.requiredString("tool")
      let (_, tool) = try tool(name)
      guard !tool.interactive else {
        throw HostError("invalid_args", "Interactive tools cannot run in an automation")
      }
      try require(context, capability: "call", scope: name)
      let (app, _) = try self.tool(name)
      let ceiling = try effectCeiling(app.id)
      external = external || ceiling == .irreversible
    }
    if external, try mode() != .trust, !approved {
      throw HostError("needs_confirmation", "This persistent plan can cause external effects")
    }
    let id = UUID().uuidString.lowercased()
    let origin = try initiator(of: context)
    var object = definition.object!
    object["initiator"] = try Value.from(origin)
    object["id"] = .string(id)
    object["createdLabels"] = try Value.from(labels(for: context))
    object["contracts"] = try automationContracts(steps, context: context)
    object["budgetUSD"] = .number(min(max(definition["budgetUSD"]?.number ?? 1, 0.1), 10))
    try db.transaction {
      try db.execute(
        "INSERT INTO automations(id,definition) VALUES (?,?)",
        [.string(id), .string(try Value.object(object).text())])
      if let pattern = trigger["event"]?.string {
        _ = try subscribe(id: "automation:" + id, pattern: pattern, context: RequestContext(origin))
      }
      try audit(
        "automation.created", context: context,
        detail: ["id": .string(id), "definition": .object(object)])
    }
    return id
  }
  public func automations() throws -> Value {
    .array(
      try db.query("SELECT * FROM automations").map { row in
        [
          "id": row["id"]!, "enabled": .bool(row["enabled"]?.int == 1),
          "definition": try Value.parse(row["definition"]!.string!),
          "lastRun": row["last_run"] ?? .null, "runsToday": row["runs_today"] ?? 0,
        ]
      })
  }
  public func setAutomation(
    _ id: String, enabled: Bool, approved: Bool = false, context: RequestContext
  ) throws {
    try require(context, capability: "automation.manage", scope: id)
    if enabled,
      let raw = try db.query("SELECT definition FROM automations WHERE id=?", [.string(id)]).first?[
        "definition"]?.string
    {
      var definition = try Value.parse(raw).object!
      let origin = try definition["initiator"]!.decode(Principal.self)
      let current = try automationContracts(
        definition["steps"]!.array!, context: RequestContext(origin))
      if current != definition["contracts"] {
        guard approved else {
          throw HostError(
            "needs_confirmation", "自动化所用工具或权限已变化，请重新确认固定计划", details: .object(definition))
        }
        definition["contracts"] = current
        try db.execute(
          "UPDATE automations SET definition=? WHERE id=?",
          [.string(try Value.object(definition).text()), .string(id)])
      }
    }
    try db.execute("UPDATE automations SET enabled=? WHERE id=?", [.bool(enabled), .string(id)])
    try audit(
      "automation.changed", context: context,
      detail: ["id": .string(id), "enabled": .bool(enabled)])
  }
  public func nextAutomation(_ id: String, now: Date = Date()) throws -> AutomationJob? {
    guard
      let row = try db.query("SELECT * FROM automations WHERE id=? AND enabled=1", [.string(id)])
        .first
    else { return nil }
    let definition = try Value.parse(row["definition"]!.string!)
    let origin = try definition["initiator"]!.decode(Principal.self)
    do {
      let contracts = try automationContracts(
        definition["steps"]!.array!, context: RequestContext(origin))
      guard contracts == definition["contracts"] else {
        throw HostError("conflict", "工具契约或权限已变化，请重新确认固定计划")
      }
    } catch {
      try db.execute("UPDATE automations SET enabled=0 WHERE id=?", [.string(id)])
      _ = try addNotification(
        title: "自动化已暂停：" + (definition["name"]?.string ?? id), body: error.localizedDescription,
        context: RequestContext(.service("automation")))
      throw error
    }
    // A session can have only one active automation run, including across host restarts.
    guard
      try db.query(
        "SELECT id FROM runs WHERE session=? AND status='running'", [.string("automation:" + id)]
      ).isEmpty
    else { return nil }
    let day = String(Self.now().prefix(10))
    let count = row["day"]?.string == day ? row["runs_today"]?.int ?? 0 : 0
    guard count < 100 else { return nil }
    var delivery: Delivery?
    if let interval = definition["trigger"]?["everySeconds"]?.number {
      guard now.timeIntervalSince1970 - (row["last_run"]?.number ?? 0) >= interval else {
        return nil
      }
    } else {
      delivery = try nextDelivery("automation:" + id, context: RequestContext(origin), now: now)
      guard delivery != nil else { return nil }
    }
    let names = definition["steps"]!.array!.compactMap { $0["tool"]?.string }
    for name in names {
      try require(RequestContext(origin), capability: "call", scope: name)
      let (_, tool) = try tool(name)
      guard !tool.interactive else {
        throw HostError("denied", "Plan now contains an interactive tool")
      }
    }
    let run = try startRun(
      session: "automation:" + id, initiator: origin, role: "automation",
      summary: definition["name"]?.string ?? id, budget: definition["budgetUSD"]?.number ?? 1,
      duration: 600, tools: names)
    let context = RequestContext(.run(run), runID: run)
    try propagate(
      (try definition["createdLabels"]!.decode(Labels.self)).union(
        delivery?.event.labels ?? Labels()), to: context)
    try db.execute(
      "UPDATE automations SET last_run=?,runs_today=?,day=? WHERE id=?",
      [.number(now.timeIntervalSince1970), .number(Double(count + 1)), .string(day), .string(id)])
    return AutomationJob(
      id: id, runID: run, definition: definition,
      event: try delivery.map { try Value.from($0.event) },
      subscriptionID: delivery?.subscriptionID, eventSequence: delivery?.sequence)
  }
  public func finishAutomation(_ job: AutomationJob, error: String? = nil) throws {
    let origin = try job.definition["initiator"]!.decode(Principal.self)
    if let subscription = job.subscriptionID, let seq = job.eventSequence {
      if let error {
        try failDelivery(subscription, sequence: seq, error: error, context: RequestContext(origin))
      } else {
        try acknowledge(subscription, sequence: seq, context: RequestContext(origin))
      }
    }
    try finishRun(job.runID, status: error == nil ? "done" : "failed")
    try audit(
      "automation.finished", context: RequestContext(.run(job.runID), runID: job.runID),
      detail: ["id": .string(job.id), "error": error.map(Value.string) ?? .null])
  }
  private func automationContracts(_ steps: [Value], context: RequestContext) throws -> Value {
    var contracts: [String: Value] = [:]
    for step in steps {
      let name = try step.requiredString("tool")
      try require(context, capability: "call", scope: name)
      let (app, tool) = try tool(name)
      guard !tool.interactive else {
        throw HostError("denied", "Interactive tools cannot run in a fixed plan")
      }
      let grants = try db.query(
        "SELECT capability,scope FROM grants WHERE holder=? AND revoked=0 AND (expires IS NULL OR expires>?) ORDER BY capability,scope",
        [.string(Principal.core(app.id).id), .number(Date().timeIntervalSince1970)])
      contracts[name] = [
        "app": .string(app.id), "input": tool.input, "output": tool.output,
        "grants": .array(grants.map(Value.object)),
      ]
    }
    return .object(contracts)
  }
}
