import Foundation

extension Kernel {
  public func hostSetting(_ key: String) throws -> String? {
    try db.query("SELECT value FROM settings WHERE key=?", [.string(key)]).first?["value"]?.string
  }
  public func setHostSetting(_ key: String, value: String?) throws {
    if let value {
      try db.execute(
        "INSERT OR REPLACE INTO settings VALUES (?,?)", [.string(key), .string(value)])
    } else {
      try db.execute("DELETE FROM settings WHERE key=?", [.string(key)])
    }
  }
  public func addNotification(title: String, body: String, context: RequestContext) throws -> String
  {
    try require(context, capability: "service", scope: "notify")
    let id = UUID().uuidString
    try db.execute(
      "INSERT INTO notifications VALUES (?,?,?,?,?,?,0)",
      [
        .string(id), .string(String(title.prefix(200))), .string(String(body.prefix(2000))),
        .string(Self.now()), .string(context.principal.id),
        .string(try Value.from(labels(for: context)).text()),
      ])
    return id
  }
  public func notifications() throws -> Value {
    .array(try db.query("SELECT * FROM notifications ORDER BY at DESC LIMIT 200").map(Value.object))
  }
  public func markNotificationRead(_ id: String) throws {
    try db.execute("UPDATE notifications SET read=1 WHERE id=?", [.string(id)])
  }
}
