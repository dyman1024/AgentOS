import Foundation

public struct Delivery: Codable, Sendable {
  public let subscriptionID: String
  public let sequence: Int
  public let event: DomainEvent
  public let attempt: Int
}
extension Kernel {
  func appendEvent(_ event: DomainEvent) throws {
    guard event.depth <= 5 else {
      try audit(
        "event.depth_exceeded", context: RequestContext(.service("bus")),
        detail: ["type": .string(event.type)])
      return
    }
    try db.execute(
      "INSERT OR IGNORE INTO events(id,type,payload,created) VALUES (?,?,?,?)",
      [
        .string(event.id), .string(event.type), .string(try Value.from(event).text()),
        .number(Date().timeIntervalSince1970),
      ])
  }
  public func events(after cursor: Int = 0, pattern: String = "*", limit: Int = 100) throws -> Value
  {
    let rows = try db.query(
      "SELECT seq,type,payload FROM events WHERE seq>? ORDER BY seq LIMIT ?",
      [.number(Double(cursor)), .number(Double(min(max(1, limit), 1000)))])
    return .array(
      try rows.filter { matchesPattern(pattern, $0["type"]!.string!) }.map {
        ["cursor": $0["seq"]!, "event": try Value.parse($0["payload"]!.string!)]
      })
  }
  @discardableResult public func subscribe(
    id: String = UUID().uuidString, pattern: String, fromBeginning: Bool = false,
    context: RequestContext
  ) throws -> String {
    try require(context, capability: "subscribe", scope: pattern)
    let cursor =
      fromBeginning
      ? 0 : (try db.query("SELECT MAX(seq) AS last FROM events").first?["last"]?.int ?? 0)
    try db.transaction {
      if let row = try db.query(
        "SELECT holder,pattern FROM subscriptions WHERE id=?", [.string(id)]
      ).first {
        guard row["holder"]?.string == context.principal.id, row["pattern"]?.string == pattern
        else { throw HostError("conflict", "Subscription identity changed") }
      } else {
        try db.execute(
          "INSERT INTO subscriptions(id,holder,pattern,cursor) VALUES (?,?,?,?)",
          [.string(id), .string(context.principal.id), .string(pattern), .number(Double(cursor))])
        try audit(
          "subscription.created", context: context,
          detail: ["id": .string(id), "pattern": .string(pattern)])
      }
    }
    return id
  }
  public func nextDelivery(
    _ id: String, context: RequestContext, now: Date = Date(), leaseSeconds: Double = 30
  ) throws -> Delivery? {
    guard leaseSeconds > 0, leaseSeconds <= 300 else {
      throw HostError("invalid_args", "Invalid delivery lease")
    }
    guard let row = try db.query("SELECT * FROM subscriptions WHERE id=?", [.string(id)]).first
    else { throw HostError("not_found", "Unknown subscription") }
    guard row["holder"]?.string == context.principal.id else {
      throw HostError("denied", "Subscription belongs to a different principal")
    }
    try require(context, capability: "subscribe", scope: row["pattern"]!.string!)
    guard row["paused"]?.int == 0, (row["retry_at"]?.number ?? 0) <= now.timeIntervalSince1970,
      (row["lease"]?.number ?? 0) <= now.timeIntervalSince1970
    else { return nil }
    let pattern = row["pattern"]!.string!
    let cursor = row["cursor"]!.int!
    let rows = try db.query(
      "SELECT seq,type,payload FROM events WHERE seq>? ORDER BY seq LIMIT 1000",
      [.number(Double(cursor))])
    for item in rows {
      let seq = item["seq"]!.int!
      guard matchesPattern(pattern, item["type"]!.string!) else {
        try db.execute(
          "UPDATE subscriptions SET cursor=? WHERE id=?", [.number(Double(seq)), .string(id)])
        continue
      }
      let event = try Value.parse(item["payload"]!.string!).decode(DomainEvent.self)
      if let collection = event.data["collection"]?.string {
        try require(context, capability: "data.read", scope: collection)
      }
      try propagate(event.labels, to: context)
      let attempts = row["event_seq"]?.int == seq ? (row["attempts"]?.int ?? 0) + 1 : 1
      if attempts > 5 {
        try failDelivery(
          id, sequence: seq, error: "Delivery lease repeatedly expired", context: context, now: now)
        return nil
      }
      try db.execute(
        "UPDATE subscriptions SET event_seq=?,lease=?,attempts=? WHERE id=?",
        [
          .number(Double(seq)), .number(now.timeIntervalSince1970 + leaseSeconds),
          .number(Double(attempts)), .string(id),
        ])
      return Delivery(subscriptionID: id, sequence: seq, event: event, attempt: attempts)
    }
    return nil
  }
  public func acknowledge(_ id: String, sequence: Int, context: RequestContext) throws {
    guard let row = try db.query("SELECT * FROM subscriptions WHERE id=?", [.string(id)]).first,
      row["holder"]?.string == context.principal.id, row["event_seq"]?.int == sequence
    else { throw HostError("conflict", "Only the currently delivered event can be acknowledged") }
    try require(context, capability: "subscribe", scope: row["pattern"]!.string!)
    try db.execute(
      "UPDATE subscriptions SET cursor=?,event_seq=NULL,lease=NULL,attempts=0,retry_at=0 WHERE id=?",
      [.number(Double(sequence)), .string(id)])
  }
  public func failDelivery(
    _ id: String, sequence: Int, error: String, context: RequestContext, now: Date = Date()
  ) throws {
    guard let row = try db.query("SELECT * FROM subscriptions WHERE id=?", [.string(id)]).first,
      row["holder"]?.string == context.principal.id, row["event_seq"]?.int == sequence
    else { throw HostError("conflict", "Unknown delivery") }
    let attempts = row["attempts"]!.int!
    if attempts >= 5 {
      try db.transaction {
        try db.execute(
          "INSERT OR REPLACE INTO dead_letters VALUES (?,?,?)",
          [.string(id), .number(Double(sequence)), .string(error)])
        try db.execute(
          "UPDATE subscriptions SET cursor=?,event_seq=NULL,lease=NULL,attempts=0,retry_at=0 WHERE id=?",
          [.number(Double(sequence)), .string(id)])
        try audit(
          "event.dead_letter", context: context,
          detail: [
            "subscription": .string(id), "sequence": .number(Double(sequence)),
            "error": .string(error),
          ])
      }
    } else {
      try db.execute(
        "UPDATE subscriptions SET lease=NULL,retry_at=? WHERE id=?",
        [.number(now.timeIntervalSince1970 + pow(2, Double(attempts))), .string(id)])
    }
  }
  public func subscriptions() throws -> Value {
    .array(try db.query("SELECT * FROM subscriptions").map(Value.object))
  }
  public func pauseSubscription(_ id: String, paused: Bool) throws {
    try db.execute("UPDATE subscriptions SET paused=? WHERE id=?", [.bool(paused), .string(id)])
  }
}
