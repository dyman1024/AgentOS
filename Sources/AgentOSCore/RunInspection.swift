import Foundation

extension Kernel {
  public func runCost(_ id: String) throws -> Double {
    guard
      let spent = try db.query("SELECT spent FROM runs WHERE id=?", [.string(id)]).first?["spent"]?
        .number
    else { throw HostError("not_found", "Unknown run") }
    return spent
  }
  public func initiator(of context: RequestContext) throws -> Principal {
    try validateContext(context)
    if case .run(let id) = context.principal,
      let value = try db.query("SELECT initiator FROM runs WHERE id=?", [.string(id)]).first?[
        "initiator"]?.string
    {
      return try Value.parse(value).decode(Principal.self)
    }
    return context.principal
  }
  public func remainingBudget(_ context: RequestContext) throws -> Double {
    try validateContext(context)
    guard let id = context.runID,
      let row = try db.query("SELECT budget,spent FROM runs WHERE id=?", [.string(id)]).first
    else { return 3 }
    let reserved =
      try db.query(
        "SELECT COALESCE(SUM(amount),0) AS total FROM budget_reservations WHERE run_id=?",
        [.string(id)]
      ).first?["total"]?.number ?? 0
    return max(0, row["budget"]!.number! - row["spent"]!.number! - reserved)
  }
  public func reserveBudget(_ amount: Double, context: RequestContext) throws -> String {
    guard amount.isFinite, amount > 0, let run = context.runID else {
      throw HostError("invalid_args", "Budgeted service requires an active run")
    }
    try validateContext(context)
    guard try remainingBudget(context) >= amount else {
      throw HostError("budget_exceeded", "Insufficient remaining budget")
    }
    let id = UUID().uuidString
    try db.execute(
      "INSERT INTO budget_reservations VALUES (?,?,?)",
      [.string(id), .string(run), .number(amount)])
    return id
  }
  public func settleBudget(_ id: String, actual: Double?) throws {
    if let actual, !actual.isFinite || actual < 0 {
      throw HostError("invalid_args", "Invalid usage")
    }
    if let settled = try db.query("SELECT * FROM budget_settlements WHERE id=?", [.string(id)])
      .first
    {
      // A cancelled/recovered run was charged conservatively. A later authoritative usage report
      // may reconcile it once; replay cannot refund twice or reopen the terminal run.
      guard let actual else { return }
      if let previous = settled["actual"]?.number {
        guard previous == actual else {
          throw HostError("conflict", "Budget was already finalized")
        }
        return
      }
      try db.transaction {
        let difference = actual - settled["charged"]!.number!
        try db.execute(
          "UPDATE runs SET spent=MAX(0,spent+?) WHERE id=?",
          [.number(difference), settled["run_id"]!])
        try db.execute(
          "UPDATE budget_settlements SET charged=?,actual=? WHERE id=?",
          [.number(actual), .number(actual), .string(id)])
        try audit(
          "run.usageReconciled", context: RequestContext(.run(settled["run_id"]!.string!)),
          detail: ["reservation": .string(id), "adjustmentUSD": .number(difference)])
      }
      return
    }
    guard
      let row = try db.query("SELECT * FROM budget_reservations WHERE id=?", [.string(id)]).first
    else {
      throw HostError("not_found", "Unknown budget reservation")
    }
    let cost = actual ?? row["amount"]!.number!
    try db.transaction {
      try db.execute(
        "INSERT INTO budget_settlements VALUES (?,?,?,?)",
        [.string(id), row["run_id"]!, .number(cost), actual.map(Value.number) ?? .null])
      try db.execute("DELETE FROM budget_reservations WHERE id=?", [.string(id)])
      _ = try charge(row["run_id"]!.string!, usd: cost)
    }
  }
  public func runs(limit: Int = 100) throws -> Value {
    .array(
      try db.query(
        "SELECT id,session,role,status,budget,spent,deadline,labels,summary FROM runs ORDER BY rowid DESC LIMIT ?",
        [.number(Double(min(max(1, limit), 1000)))]
      ).map(Value.object))
  }
}
