import Foundation

public struct SinkTicket: Sendable, Codable {
  public let id: String
  public let action: String
  public let args: Value
  public let state: String
  public let reason: String?
}
extension Kernel {
  public func prepareSink(
    action: String, args: Value, effect: EffectClass, capability: String, scope: String,
    knownURL: Bool = false, context: RequestContext
  ) throws -> SinkTicket {
    if capability == "net" {
      try authorizeNetwork(scope, context: context)
    } else {
      try require(context, capability: capability, scope: scope)
    }
    let id = UUID().uuidString.lowercased()
    let labels = try self.labels(for: context)
    let decision = try ExitPolicy.evaluate(
      mode: mode(), effect: effect, labels: labels, knownURL: knownURL)
    let reason: String?
    let state: String
    if case .confirm(let why) = decision, try !matchesRule(action: action, args: args) {
      state = "pending"
      reason = why
    } else if case .deny(let why) = decision {
      throw HostError("denied", why)
    } else {
      state = "ready"
      reason = nil
    }
    let envelope: Value = [
      "request": try Value.from(context), "effect": .string(effect.rawValue),
      "capability": .string(capability), "scope": .string(scope), "knownURL": .bool(knownURL),
      "expires": .number(Date().timeIntervalSince1970 + 900), "labels": try Value.from(labels),
    ]
    try db.transaction {
      try db.execute(
        "INSERT INTO sink_operations VALUES (?,?,?,?,?,?,NULL)",
        [
          .string(id), .string(try envelope.text()), .string(action), .string(try args.text()),
          .string(state), reason.map(Value.string) ?? .null,
        ])
      try db.execute(
        "INSERT INTO effects(id,run_id,principal,class,action,target,state,at) VALUES (?,?,?,?,?,?,?,?)",
        [
          .string(id), context.runID.map(Value.string) ?? .null, .string(context.principal.id),
          .string(effect.rawValue), .string(action), .string(scope), .string(state),
          .string(Self.now()),
        ])
      try audit(
        "sink.prepared", context: context,
        detail: [
          "id": .string(id), "action": .string(action), "args": args,
          "labels": try Value.from(labels), "decision": .string(state),
        ])
    }
    return SinkTicket(id: id, action: action, args: args, state: state, reason: reason)
  }
  public func approveSink(_ id: String, allow: Bool, issuer: Principal = .user) throws {
    guard issuer == .user else {
      throw HostError("denied", "Only trusted user controls can approve exits")
    }
    guard
      let row = try db.query(
        "SELECT * FROM sink_operations WHERE id=? AND state='pending'", [.string(id)]
      ).first
    else { throw HostError("conflict", "Confirmation is no longer pending") }
    let envelope = try Value.parse(row["context"]!.string!)
    let context = try envelope["request"]!.decode(RequestContext.self)
    guard envelope["expires"]!.number! > Date().timeIntervalSince1970 else {
      throw HostError("denied", "Confirmation expired")
    }
    var updated = envelope.object!
    updated["approvedLabels"] = try Value.from(labels(for: context))
    let state = allow ? "ready" : "denied"
    try db.transaction {
      try db.execute(
        "UPDATE sink_operations SET state=?,decision=?,context=? WHERE id=?",
        [
          .string(state), .string(allow ? "user-approved" : "user-denied"),
          .string(try Value.object(updated).text()), .string(id),
        ])
      try db.execute("UPDATE effects SET state=? WHERE id=?", [.string(state), .string(id)])
      try audit(
        "sink.confirmed", context: RequestContext(.user),
        detail: ["id": .string(id), "allow": .bool(allow)])
    }
  }
  // Return the stored arguments, never replacement arguments supplied after approval.
  public func claimSink(_ id: String, context: RequestContext) throws -> Value {
    guard let row = try db.query("SELECT * FROM sink_operations WHERE id=?", [.string(id)]).first
    else { throw HostError("not_found", "Unknown exit operation") }
    guard row["state"] == "ready" else {
      throw HostError(
        row["state"] == "pending" ? "needs_confirmation" : "conflict", "Exit is not executable",
        details: ["operationID": .string(id)])
    }
    let envelope = try Value.parse(row["context"]!.string!)
    let bound = try envelope["request"]!.decode(RequestContext.self)
    guard bound.principal == context.principal, bound.runID == context.runID,
      bound.instanceID == context.instanceID,
      envelope["expires"]!.number! > Date().timeIntervalSince1970
    else { throw HostError("denied", "Exit context or deadline changed") }
    let capability = envelope["capability"]!.string!
    let scope = envelope["scope"]!.string!
    if capability == "net" {
      try authorizeNetwork(scope, context: context)
    } else {
      try require(context, capability: capability, scope: scope)
    }
    let labels = try self.labels(for: context)
    let args = try Value.parse(row["args"]!.string!)
    let policy = try ExitPolicy.evaluate(
      mode: mode(), effect: EffectClass(rawValue: envelope["effect"]!.string!)!, labels: labels,
      knownURL: envelope["knownURL"]?.bool ?? false)
    if case .confirm(let reason) = policy, envelope["approvedLabels"] != (try Value.from(labels)),
      try !matchesRule(action: row["action"]!.string!, args: args)
    {
      try db.execute(
        "UPDATE sink_operations SET state='pending',decision=? WHERE id=?",
        [.string(reason), .string(id)])
      try db.execute("UPDATE effects SET state='pending' WHERE id=?", [.string(id)])
      throw HostError("needs_confirmation", reason, details: ["operationID": .string(id)])
    }
    try db.transaction {
      try db.execute("UPDATE sink_operations SET state='executing' WHERE id=?", [.string(id)])
      try db.execute("UPDATE effects SET state='executing' WHERE id=?", [.string(id)])
      try audit("sink.executing", context: context, detail: ["id": .string(id)])
    }
    return args
  }
  public func finishSink(_ id: String, state: String, result: Value) throws {
    guard ["done", "failed", "unknown", "compensated"].contains(state),
      let row = try db.query(
        "SELECT * FROM sink_operations WHERE id=? AND state IN ('executing','done','unknown')",
        [.string(id)]
      ).first
    else { throw HostError("conflict", "Invalid exit transition") }
    let context = try Value.parse(row["context"]!.string!)["request"]!.decode(RequestContext.self)
    try db.transaction {
      try db.execute(
        "UPDATE sink_operations SET state=?,result=? WHERE id=?",
        [.string(state), .string(try result.text()), .string(id)])
      try db.execute("UPDATE effects SET state=? WHERE id=?", [.string(state), .string(id)])
      try audit("sink." + state, context: context, detail: ["id": .string(id), "result": result])
    }
  }
  public func pendingSinks() throws -> Value {
    .array(
      try db.query(
        "SELECT id,action,args,state,decision FROM sink_operations WHERE state IN ('pending','unknown')"
      ).map(Value.object))
  }
  public func addRule(action: String, equals: Value, issuer: Principal = .user) throws -> String {
    guard issuer == .user, let fields = equals.object, !fields.isEmpty, fields.count <= 10,
      action.count <= 100
    else { throw HostError("denied", "A trusted user must specify exact parameters for a rule") }
    let id = UUID().uuidString
    try db.transaction {
      try db.execute(
        "INSERT INTO exit_rules VALUES (?,?,?,1)",
        [.string(id), .string(action), .string(try equals.text())])
      try audit(
        "rule.created", context: RequestContext(.user),
        detail: ["id": .string(id), "action": .string(action), "equals": equals])
    }
    return id
  }
  public func rules() throws -> Value {
    .array(try db.query("SELECT * FROM exit_rules WHERE enabled=1").map(Value.object))
  }
  public func removeRule(_ id: String, issuer: Principal = .user) throws {
    guard issuer == .user else { throw HostError("denied", "Only user controls can change rules") }
    try db.execute("UPDATE exit_rules SET enabled=0 WHERE id=?", [.string(id)])
    try audit("rule.removed", context: RequestContext(.user), detail: ["id": .string(id)])
  }
  func matchesRule(action: String, args: Value) throws -> Bool {
    for row in try db.query(
      "SELECT parameters FROM exit_rules WHERE action=? AND enabled=1", [.string(action)])
    {
      let fields = try Value.parse(row["parameters"]!.string!).object ?? [:]
      if !fields.isEmpty, fields.allSatisfy({ args[$0.key] == $0.value }) { return true }
    }
    return false
  }
}
