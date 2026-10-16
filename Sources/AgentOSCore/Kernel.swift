import CryptoKit
import Foundation

public actor Kernel {
  let db: SQLiteStore
  public let root: URL
  public func shutdown() throws { try db.close() }
  public init(root: URL, recover: Bool = true) throws {
    self.root = root
    let system = root.appendingPathComponent("system", isDirectory: true)
    try FileManager.default.createDirectory(
      at: system, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    db = try SQLiteStore(path: system.appendingPathComponent("kernel.sqlite").path)
    try Self.migrate(db)
    if recover {
      try db.transaction {
        try db.execute(
          "INSERT OR IGNORE INTO budget_settlements SELECT id,run_id,amount,NULL FROM budget_reservations"
        )
        try db.execute(
          "UPDATE runs SET spent=spent+(SELECT COALESCE(SUM(amount),0) FROM budget_reservations b WHERE b.run_id=runs.id)"
        )
        try db.execute("DELETE FROM budget_reservations")
      }
      try db.execute("UPDATE runs SET status='interrupted' WHERE status='running'")
      try db.execute("UPDATE sink_operations SET state='unknown' WHERE state='executing'")
      try db.execute("UPDATE effects SET state='unknown' WHERE state='executing'")
    }
  }
  private static func migrate(_ db: SQLiteStore) throws {
    for sql in [
      "CREATE TABLE IF NOT EXISTS notifications (id TEXT PRIMARY KEY,title TEXT NOT NULL,body TEXT NOT NULL,at TEXT NOT NULL,source TEXT NOT NULL,labels TEXT NOT NULL,read INTEGER NOT NULL DEFAULT 0)",
      "CREATE TABLE IF NOT EXISTS known_urls (run_id TEXT NOT NULL,url TEXT NOT NULL,PRIMARY KEY(run_id,url))",
      "CREATE TABLE IF NOT EXISTS folders (id TEXT PRIMARY KEY,title TEXT NOT NULL,bookmark TEXT NOT NULL,enabled INTEGER NOT NULL DEFAULT 1)",
      "CREATE TABLE IF NOT EXISTS file_history (effect_id TEXT PRIMARY KEY,folder TEXT NOT NULL,path TEXT NOT NULL,before_data TEXT,after_hash TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS directory_history (id TEXT PRIMARY KEY,folder TEXT NOT NULL,path TEXT NOT NULL,device TEXT NOT NULL,inode TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS service_usage (holder TEXT NOT NULL,service TEXT NOT NULL,day TEXT NOT NULL,count INTEGER NOT NULL,PRIMARY KEY(holder,service,day))",
      "CREATE TABLE IF NOT EXISTS budget_settlements (id TEXT PRIMARY KEY,run_id TEXT NOT NULL,charged REAL NOT NULL,actual REAL)",
      "CREATE TABLE IF NOT EXISTS budget_reservations (id TEXT PRIMARY KEY,run_id TEXT NOT NULL,amount REAL NOT NULL)",
      "CREATE TABLE IF NOT EXISTS embeddings (collection TEXT NOT NULL,id TEXT NOT NULL,model TEXT NOT NULL,rev INTEGER NOT NULL,vector TEXT NOT NULL,PRIMARY KEY(collection,id,model))",
      "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, labels TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, session TEXT NOT NULL, initiator TEXT NOT NULL, role TEXT NOT NULL, status TEXT NOT NULL, budget REAL NOT NULL, spent REAL NOT NULL DEFAULT 0, deadline REAL NOT NULL, labels TEXT NOT NULL, summary TEXT NOT NULL, tools TEXT)",
      "CREATE TABLE IF NOT EXISTS instances (id TEXT PRIMARY KEY, principal TEXT NOT NULL, labels TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS grants (id TEXT PRIMARY KEY, holder TEXT NOT NULL, capability TEXT NOT NULL, scope TEXT NOT NULL, expires REAL, revoked INTEGER NOT NULL DEFAULT 0)",
      "CREATE TABLE IF NOT EXISTS schemas (collection TEXT PRIMARY KEY, type TEXT NOT NULL, definition TEXT NOT NULL, private INTEGER NOT NULL DEFAULT 0)",
      "CREATE TABLE IF NOT EXISTS schema_versions (collection TEXT NOT NULL,version INTEGER NOT NULL,definition TEXT NOT NULL,PRIMARY KEY(collection,version))",
      "CREATE TABLE IF NOT EXISTS records (collection TEXT NOT NULL, id TEXT NOT NULL, rev INTEGER NOT NULL, fields TEXT NOT NULL, labels TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(collection,id))",
      "CREATE TABLE IF NOT EXISTS recovery_sources (effect_id TEXT NOT NULL,source_id TEXT NOT NULL,before_state TEXT NOT NULL,after_state TEXT NOT NULL,PRIMARY KEY(effect_id,source_id))",
      "CREATE TABLE IF NOT EXISTS history (seq INTEGER PRIMARY KEY AUTOINCREMENT, collection TEXT NOT NULL, id TEXT NOT NULL, rev INTEGER NOT NULL, before TEXT, after TEXT NOT NULL, effect_id TEXT NOT NULL, changed TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS effects (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, run_id TEXT, principal TEXT NOT NULL, class TEXT NOT NULL, action TEXT NOT NULL, target TEXT NOT NULL, state TEXT NOT NULL, at TEXT NOT NULL, undo_of TEXT)",
      "CREATE TABLE IF NOT EXISTS audit (seq INTEGER PRIMARY KEY AUTOINCREMENT, payload TEXT NOT NULL, prev_hash TEXT NOT NULL, hash TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, type TEXT NOT NULL, payload TEXT NOT NULL, created REAL NOT NULL)",
      "CREATE INDEX IF NOT EXISTS history_record ON history(collection,id,rev)",
      "CREATE INDEX IF NOT EXISTS effects_run ON effects(run_id)",
      "CREATE VIRTUAL TABLE IF NOT EXISTS records_fts USING fts5(collection UNINDEXED,id UNINDEXED,text,tokenize='trigram')",
      "CREATE TABLE IF NOT EXISTS subscriptions (id TEXT PRIMARY KEY, holder TEXT NOT NULL, pattern TEXT NOT NULL, cursor INTEGER NOT NULL, paused INTEGER NOT NULL DEFAULT 0, event_seq INTEGER, lease REAL, attempts INTEGER NOT NULL DEFAULT 0, retry_at REAL NOT NULL DEFAULT 0)",
      "CREATE TABLE IF NOT EXISTS dead_letters (subscription TEXT NOT NULL, event_seq INTEGER NOT NULL, error TEXT NOT NULL, PRIMARY KEY(subscription,event_seq))",
      "CREATE TABLE IF NOT EXISTS package_labels (app_id TEXT PRIMARY KEY,labels TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS packages (id TEXT PRIMARY KEY, namespace TEXT UNIQUE NOT NULL, version TEXT NOT NULL, manifest TEXT NOT NULL, interface TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS app_versions (app_id TEXT NOT NULL, version TEXT NOT NULL, digest TEXT NOT NULL, activated TEXT NOT NULL, PRIMARY KEY(app_id,version))",
      "CREATE TABLE IF NOT EXISTS automations (id TEXT PRIMARY KEY, definition TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, last_run REAL, runs_today INTEGER NOT NULL DEFAULT 0, day TEXT)",
      "CREATE TABLE IF NOT EXISTS exit_rules (id TEXT PRIMARY KEY,action TEXT NOT NULL,parameters TEXT NOT NULL,enabled INTEGER NOT NULL)",
      "CREATE TABLE IF NOT EXISTS sink_operations (id TEXT PRIMARY KEY, context TEXT NOT NULL, action TEXT NOT NULL, args TEXT NOT NULL, state TEXT NOT NULL, decision TEXT, result TEXT)",
    ] { try db.execute(sql) }
    let columns = Set(try db.query("PRAGMA table_info(records)").compactMap { $0["name"]?.string })
    for column in ["created_by", "created_at", "updated_by", "updated_at"]
    where !columns.contains(column) {
      try db.execute("ALTER TABLE records ADD COLUMN \(column) TEXT")
    }
    for (collection, type, definition, isPrivate) in SystemSchemas.entries {
      try db.execute(
        "INSERT OR IGNORE INTO schemas VALUES (?,?,?,?)",
        [.string(collection), .string(type), .string(try definition.text()), .bool(isPrivate)])
    }
    try db.execute(
      "INSERT OR IGNORE INTO schema_versions SELECT collection,1,definition FROM schemas")
  }

  public func registerSchema(
    collection: String, type: String, definition: Value, isPrivate: Bool = false, version: Int = 1,
    context: RequestContext
  ) throws {
    try require(context, capability: "schemas.register", scope: collection)
    guard version > 0, version <= 10000, Self.validName(collection),
      type.range(of: "^[a-z][a-z0-9_.-]{0,63}$", options: .regularExpression) != nil
    else {
      throw HostError("invalid_args", "Invalid collection or type name")
    }
    try Schema.lint(definition)
    guard
      try db.query(
        "SELECT collection FROM schemas WHERE type=? AND collection<>?",
        [.string(type), .string(collection)]
      ).isEmpty
    else { throw HostError("conflict", "Schema type already belongs to another collection") }
    if let existing = try db.query(
      "SELECT definition,type,private FROM schemas WHERE collection=?", [.string(collection)]
    ).first {
      guard existing["definition"]?.string == (try definition.text()),
        existing["type"]?.string == type,
        existing["private"]?.int == (isPrivate ? 1 : 0)
      else {
        throw HostError("conflict", "Schema already exists; use a new version")
      }
      return
    }
    try db.transaction {
      try db.execute(
        "INSERT INTO schemas VALUES (?,?,?,?)",
        [.string(collection), .string(type), .string(try definition.text()), .bool(isPrivate)])
      try db.execute(
        "INSERT INTO schema_versions VALUES (?,?,?)",
        [.string(collection), .number(Double(version)), .string(try definition.text())])
      try audit("schema.register", context: context, detail: ["collection": .string(collection)])
    }
  }
  public static func validName(_ value: String) -> Bool {
    value.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil
  }
  public func schemas() throws -> Value {
    .array(
      try db.query(
        "SELECT s.*, (SELECT MAX(version) FROM schema_versions v WHERE v.collection=s.collection) AS version FROM schemas s ORDER BY collection"
      ).map { .object($0) })
  }
  public func startRun(
    session: String, initiator: Principal = .user, role: String = "operator", summary: String = "",
    budget: Double = 3, duration: TimeInterval = 600, tools: [String]? = nil
  ) throws -> String {
    guard budget.isFinite, budget > 0, duration > 0, duration <= 86400 else {
      throw HostError("invalid_args", "Invalid run limits")
    }
    if case .run = initiator {
      throw HostError("invalid_args", "Nested runs require an application or user initiator")
    }
    let id = UUID().uuidString.lowercased()
    try db.transaction {
      try db.execute(
        "INSERT OR IGNORE INTO sessions VALUES (?,?)",
        [.string(session), .string(try Value.from(Labels()).text())])
      let labels = try db.query("SELECT labels FROM sessions WHERE id=?", [.string(session)])
        .first!["labels"]!
      try db.execute(
        "INSERT INTO runs (id,session,initiator,role,status,budget,deadline,labels,summary,tools) VALUES (?,?,?,?,'running',?,?,?,?,?)",
        [
          .string(id), .string(session), .string(try Value.from(initiator).text()), .string(role),
          .number(budget), .number(Date().timeIntervalSince1970 + duration), labels,
          .string(summary),
          tools.map { .string((try? Value.array($0.map(Value.string)).text()) ?? "[]") } ?? .null,
        ])
      try audit(
        "run.started", context: RequestContext(.run(id), runID: id),
        detail: ["summary": .string(summary)])
    }
    return id
  }
  public func finishRun(_ id: String, status: String = "done") throws {
    guard ["done", "failed", "cancelled"].contains(status) else {
      throw HostError("invalid_args", "Invalid terminal state")
    }
    try db.transaction {
      for row in try db.query("SELECT id FROM budget_reservations WHERE run_id=?", [.string(id)]) {
        try settleBudget(row["id"]!.string!, actual: nil)
      }
      try db.execute(
        "UPDATE runs SET status=? WHERE id=? AND status='running'", [.string(status), .string(id)])
      try audit("run.\(status)", context: RequestContext(.run(id), runID: id), detail: [:])
    }
  }
  public func charge(_ id: String, usd: Double) throws -> Bool {
    guard usd.isFinite, usd >= 0 else { throw HostError("invalid_args", "Invalid cost") }
    return try db.transaction {
      try db.execute("UPDATE runs SET spent=spent+? WHERE id=?", [.number(usd), .string(id)])
      guard let row = try db.query("SELECT * FROM runs WHERE id=?", [.string(id)]).first else {
        throw HostError("not_found", "Unknown run")
      }
      let exceeded = row["spent"]!.number! >= row["budget"]!.number!
      if exceeded { try db.execute("UPDATE runs SET status='cancelled' WHERE id=?", [.string(id)]) }
      try audit(
        "run.usage", context: RequestContext(.run(id), runID: id), detail: ["usd": .number(usd)])
      return exceeded
    }
  }
  public func bindInstance(_ id: String, principal: Principal, preserveLabels: Bool = true) throws {
    if let existing = try db.query("SELECT principal FROM instances WHERE id=?", [.string(id)])
      .first
    {
      guard existing["principal"]?.string == principal.id else {
        throw HostError("denied", "Instance identity is immutable")
      }
      if !preserveLabels {
        try db.execute(
          "UPDATE instances SET labels=? WHERE id=?",
          [.string(try Value.from(Labels()).text()), .string(id)])
      }
    } else {
      try db.execute(
        "INSERT INTO instances VALUES (?,?,?)",
        [.string(id), .string(principal.id), .string(try Value.from(Labels()).text())])
    }
  }
  @discardableResult public func grant(
    holder: Principal, capability: String, scope: String, expires: Date? = nil,
    issuer: Principal = .user
  ) throws -> String {
    guard issuer == .user else {
      throw HostError("denied", "Grant creation must be approved by the trusted host")
    }
    let id = UUID().uuidString
    try db.transaction {
      try db.execute(
        "INSERT INTO grants (id,holder,capability,scope,expires) VALUES (?,?,?,?,?)",
        [
          .string(id), .string(holder.id), .string(capability), .string(scope),
          expires.map { .number($0.timeIntervalSince1970) } ?? .null,
        ])
      try audit(
        "grant.created", context: RequestContext(.user),
        detail: [
          "holder": .string(holder.id), "capability": .string(capability), "scope": .string(scope),
        ])
    }
    return id
  }
  public func revoke(_ id: String, issuer: Principal = .user) throws {
    guard issuer == .user else { throw HostError("denied", "Only the user may revoke grants") }
    try db.transaction {
      try db.execute("UPDATE grants SET revoked=1 WHERE id=?", [.string(id)])
      try audit("grant.revoked", context: RequestContext(.user), detail: ["id": .string(id)])
    }
  }
  public func grants() throws -> Value {
    .array(try db.query("SELECT * FROM grants WHERE revoked=0").map(Value.object))
  }
  func require(_ context: RequestContext, capability: String, scope: String) throws {
    do {
      try validateContext(context)
      try check(context.principal, capability: capability, scope: scope)
    } catch {
      try? audit(
        "access.denied", context: context,
        detail: ["capability": .string(capability), "scope": .string(scope)])
      throw error
    }
  }
  public func validateContext(_ context: RequestContext) throws {
    guard context.depth <= 8 else { throw HostError("denied", "Call depth exceeded") }
    if let instance = context.instanceID {
      guard
        try db.query("SELECT principal FROM instances WHERE id=?", [.string(instance)]).first?[
          "principal"]?.string == context.principal.id
      else { throw HostError("denied", "Unbound instance") }
    }
    if let id = context.runID { try checkRun(id) }
    if case .run(let id) = context.principal { try checkRun(id) }
  }
  private func checkRun(_ id: String) throws {
    guard let row = try db.query("SELECT * FROM runs WHERE id=?", [.string(id)]).first,
      row["status"]?.string == "running", row["deadline"]!.number! > Date().timeIntervalSince1970,
      row["spent"]!.number! < row["budget"]!.number!
    else { throw HostError("denied", "Run is inactive, expired or out of budget") }
  }
  private func check(_ principal: Principal, capability: String, scope: String) throws {
    switch principal {
    case .user, .service: return
    case .run(let id):
      try checkRun(id)
      let row = try db.query("SELECT initiator,tools FROM runs WHERE id=?", [.string(id)]).first!
      if capability == "call", let tools = row["tools"]?.string {
        let allowed = try Value.parse(tools).array?.compactMap(\.string) ?? []
        guard allowed.contains(where: { matchesPattern($0, scope) }) else {
          throw HostError("denied", "Tool is outside the fixed automation plan")
        }
      }
      let origin = try Value.parse(row["initiator"]!.string!).decode(Principal.self)
      try check(origin, capability: capability, scope: scope)
    case .ui(let app):
      guard capability == "data.read" || capability == "self.call" else {
        throw HostError("denied", "Application UI is read-only")
      }
      if capability == "self.call" { return }
      try check(.core(app), capability: capability, scope: scope)
    case .core:
      let grants = try db.query(
        "SELECT scope FROM grants WHERE holder=? AND capability=? AND revoked=0 AND (expires IS NULL OR expires>?)",
        [.string(principal.id), .string(capability), .number(Date().timeIntervalSince1970)])
      guard grants.contains(where: { matchesPattern($0["scope"]!.string!, scope) }) else {
        throw HostError("denied", "Missing \(capability) grant for \(scope)")
      }
    }
  }
  public func authorize(_ context: RequestContext, capability: String, scope: String) throws {
    try require(context, capability: capability, scope: scope)
  }
  public func labels(for context: RequestContext) throws -> Labels {
    var result = Labels()
    if let id = context.runID
      ?? {
        if case .run(let id) = context.principal { return id }
        return nil
      }(),
      let row = try db.query("SELECT labels FROM runs WHERE id=?", [.string(id)]).first
    {
      result = result.union(try Value.parse(row["labels"]!.string!).decode(Labels.self))
    }
    if let id = context.instanceID,
      let row = try db.query("SELECT labels FROM instances WHERE id=?", [.string(id)]).first
    {
      result = result.union(try Value.parse(row["labels"]!.string!).decode(Labels.self))
    }
    return result
  }
  public func propagate(_ labels: Labels, to context: RequestContext) throws {
    let merged = try self.labels(for: context).union(labels)
    let text = try Value.from(merged).text()
    let runID =
      context.runID
      ?? {
        if case .run(let id) = context.principal { return id }
        return nil
      }()
    if let id = runID {
      try db.execute("UPDATE runs SET labels=? WHERE id=?", [.string(text), .string(id)])
      if let session = try db.query("SELECT session FROM runs WHERE id=?", [.string(id)]).first?[
        "session"]
      {
        let old = try db.query("SELECT labels FROM sessions WHERE id=?", [session]).first![
          "labels"]!.string!
        let combined = try Value.parse(old).decode(Labels.self).union(merged)
        try db.execute(
          "UPDATE sessions SET labels=? WHERE id=?",
          [.string(try Value.from(combined).text()), session])
      }
    }
    if let id = context.instanceID {
      try db.execute("UPDATE instances SET labels=? WHERE id=?", [.string(text), .string(id)])
    }
  }
  public func setMode(_ mode: PermissionMode) throws {
    try db.execute("INSERT OR REPLACE INTO settings VALUES ('mode',?)", [.string(mode.rawValue)])
  }
  public func mode() throws -> PermissionMode {
    PermissionMode(
      rawValue: try db.query("SELECT value FROM settings WHERE key='mode'").first?["value"]?.string
        ?? "auto") ?? .auto
  }
  func audit(_ kind: String, context: RequestContext, detail: Value) throws {
    let previous =
      try db.query("SELECT hash FROM audit ORDER BY seq DESC LIMIT 1").first?["hash"]?.string ?? ""
    let payload: Value = [
      "kind": .string(kind), "principal": .string(context.principal.id),
      "runID": context.runID.map(Value.string) ?? .null, "at": .string(Self.now()),
      "detail": detail,
    ]
    let text = try payload.text()
    let hash = Self.digest(Data((previous + "\n" + text).utf8))
    try db.execute(
      "INSERT INTO audit(payload,prev_hash,hash) VALUES (?,?,?)",
      [.string(text), .string(previous), .string(hash)])
  }
  public func verifyAudit() throws -> Bool {
    var previous = ""
    for row in try db.query("SELECT * FROM audit ORDER BY seq") {
      guard row["prev_hash"]?.string == previous,
        let payload = row["payload"]?.string, let hash = row["hash"]?.string,
        Self.digest(Data((previous + "\n" + payload).utf8)) == hash
      else { return false }
      previous = hash
    }
    return true
  }
  public func auditEntries(limit: Int = 100) throws -> Value {
    .array(
      try db.query(
        "SELECT payload FROM audit ORDER BY seq DESC LIMIT ?",
        [.number(Double(min(max(1, limit), 1000)))]
      ).map { try Value.parse($0["payload"]!.string!) })
  }
  public static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}
