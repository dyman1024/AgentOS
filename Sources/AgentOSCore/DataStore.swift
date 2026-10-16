import Foundation

extension Kernel {
  public func get(_ collection: String, id: String, context: RequestContext) throws -> Record {
    try require(context, capability: "data.read", scope: collection)
    guard let record = try readRecord(collection, id: id), !record.deleted else {
      throw HostError("not_found", "Record not found")
    }
    try propagate(record.labels, to: context)
    if record.labels.isPrivate {
      try audit(
        "data.read", context: context,
        detail: ["collection": .string(collection), "id": .string(id)])
    }
    return record
  }
  public func query(
    _ collection: String, text: String = "", where filters: [String: Value] = [:],
    orderBy: String = "_id", limit: Int = 100, context: RequestContext
  ) throws -> [Record] {
    try require(context, capability: "data.read", scope: collection)
    guard
      try db.query("SELECT collection FROM schemas WHERE collection=?", [.string(collection)]).first
        != nil
    else { throw HostError("not_found", "Unknown collection") }
    var sql = "SELECT r.* FROM records r WHERE r.collection=? AND r.deleted=0"
    var parameters: [Value] = [.string(collection)]
    if !text.isEmpty {
      if text.count >= 3 {
        sql +=
          " AND r.id IN (SELECT id FROM records_fts WHERE records_fts MATCH ? AND collection=?)"
        parameters += [
          .string("\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""),
          .string(collection),
        ]
      } else {
        sql += " AND instr(lower(r.fields),lower(?))>0"
        parameters += [.string(text)]
      }
    }
    sql += " ORDER BY r.id LIMIT 10001"
    let rows = try db.query(sql, parameters)
    guard rows.count <= 10000 else {
      throw HostError("invalid_args", "Query too broad; add a search term")
    }
    var records = try rows.map(record).filter { r in
      filters.allSatisfy { field, value in Self.matches(r.value[field], value) }
    }
    let descending = orderBy.hasPrefix("-")
    let key = descending ? String(orderBy.dropFirst()) : orderBy
    records.sort { a, b in
      let av = key == "_id" ? Value.string(a.id) : a.value[key] ?? .null
      let bv = key == "_id" ? Value.string(b.id) : b.value[key] ?? .null
      if av == bv { return a.id < b.id }
      let less: Bool
      if let x = av.number, let y = bv.number {
        less = x < y
      } else {
        less = (av.string ?? "") < (bv.string ?? "")
      }
      return descending ? !less : less
    }
    let result = Array(records.prefix(min(max(1, limit), 1000)))
    for r in result { try propagate(r.labels, to: context) }
    if result.contains(where: { $0.labels.isPrivate }) {
      try audit(
        "data.query", context: context,
        detail: ["collection": .string(collection), "count": .number(Double(result.count))])
    }
    return result
  }
  static func matches(_ actual: Value?, _ expected: Value) -> Bool {
    guard actual != nil else { return false }
    guard let ops = expected.object else { return actual == expected }
    return ops.allSatisfy { op, v in
      switch op {
      case "has": return actual?.array?.contains(v) == true
      case "prefix": return actual?.string?.hasPrefix(v.string ?? "") == true
      case "lt":
        if let a = actual?.number, let b = v.number { return a < b }
        return (actual?.string ?? "") < (v.string ?? "")
      case "gt":
        if let a = actual?.number, let b = v.number { return a > b }
        return (actual?.string ?? "") > (v.string ?? "")
      case "eq": return actual == v
      default: return false
      }
    }
  }
  public func put(
    _ collection: String, id: String? = nil, fields: [String: Value], expectedRevision: Int? = nil,
    context: RequestContext
  ) throws -> MutationResult {
    try batch(
      [Mutation(collection, id: id, fields: fields, expectedRevision: expectedRevision)],
      context: context)[0]
  }
  public func delete(
    _ collection: String, id: String, expectedRevision: Int, context: RequestContext
  ) throws -> MutationResult {
    try batch(
      [Mutation(collection, id: id, expectedRevision: expectedRevision, delete: true)],
      context: context)[0]
  }
  public func batch(_ mutations: [Mutation], context: RequestContext) throws -> [MutationResult] {
    guard !mutations.isEmpty, mutations.count <= 100 else {
      throw HostError("invalid_args", "Batch size must be 1–100")
    }
    for m in mutations { try require(context, capability: "data.write", scope: m.collection) }
    return try db.transaction { try mutations.map { try apply($0, context: context) } }
  }
  func apply(
    _ mutation: Mutation, context: RequestContext, undoOf: String? = nil,
    restoredLabels: Labels? = nil, restoreDeletedFields: Bool = false
  ) throws -> MutationResult {
    let collection = mutation.collection
    let id = mutation.id ?? UUID().uuidString.lowercased()
    guard id.count <= 128, !id.isEmpty, !id.contains("/"),
      !mutation.fields.keys.contains(where: { $0.hasPrefix("_") })
    else { throw HostError("invalid_args", "Invalid record identifier or reserved metadata field") }
    guard
      let schema = try db.query("SELECT * FROM schemas WHERE collection=?", [.string(collection)])
        .first
    else { throw HostError("not_found", "Unknown collection") }
    let before = try readRecord(collection, id: id)
    if let before {
      guard mutation.expectedRevision == before.rev else {
        throw HostError(
          "conflict", "Record revision changed",
          details: ["currentRevision": .number(Double(before.rev))])
      }
      if before.deleted && undoOf == nil {
        throw HostError("conflict", "Deleted record must be restored through history")
      }
    } else if mutation.expectedRevision != nil || mutation.delete {
      throw HostError("not_found", "Record not found")
    }
    let fields =
      mutation.delete && !restoreDeletedFields ? (before?.fields ?? [:]) : mutation.fields
    if !mutation.delete || restoreDeletedFields {
      try Schema.validate(.object(fields), against: Value.parse(schema["definition"]!.string!))
    }
    let labels = try self.labels(for: context).union(before?.labels ?? Labels()).union(
      restoredLabels ?? Labels()
    ).union(Labels(isPrivate: schema["private"]?.int == 1))
    let rev = (before?.rev ?? 0) + 1
    let timestamp = Self.now()
    let after = Record(
      collection: collection, id: id, rev: rev, fields: fields, labels: labels,
      deleted: mutation.delete, createdBy: before?.createdBy ?? context.principal.id,
      createdAt: before?.createdAt ?? timestamp, updatedBy: context.principal.id,
      updatedAt: timestamp)
    let effectID = UUID().uuidString.lowercased()
    let changed = Self.changedFields(before, after)
    try db.execute(
      "INSERT INTO records(collection,id,rev,fields,labels,deleted,created_by,created_at,updated_by,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(collection,id) DO UPDATE SET rev=excluded.rev,fields=excluded.fields,labels=excluded.labels,deleted=excluded.deleted,updated_by=excluded.updated_by,updated_at=excluded.updated_at",
      [
        .string(collection), .string(id), .number(Double(rev)),
        .string(try Value.object(fields).text()), .string(try Value.from(labels).text()),
        .bool(mutation.delete), .string(after.createdBy!), .string(after.createdAt!),
        .string(after.updatedBy!), .string(after.updatedAt!),
      ])
    try db.execute(
      "INSERT INTO history(collection,id,rev,before,after,effect_id,changed) VALUES (?,?,?,?,?,?,?)",
      [
        .string(collection), .string(id), .number(Double(rev)),
        try before.map { .string(try Value.from($0).text()) } ?? .null,
        .string(try Value.from(after).text()), .string(effectID),
        .string(try Value.array(changed.sorted().map(Value.string)).text()),
      ])
    try db.execute(
      "DELETE FROM records_fts WHERE collection=? AND id=?", [.string(collection), .string(id)])
    if !after.deleted {
      let content = fields.values.compactMap(\.string).joined(separator: " ")
      try db.execute(
        "INSERT INTO records_fts(collection,id,text) VALUES (?,?,?)",
        [.string(collection), .string(id), .string(content)])
    }
    let action = undoOf == nil ? (mutation.delete ? "data.delete" : "data.put") : "data.restore"
    try db.execute(
      "INSERT INTO effects(id,run_id,principal,class,action,target,state,at,undo_of) VALUES (?,?,?,'write',?,?,'applied',?,?)",
      [
        .string(effectID), context.runID.map(Value.string) ?? .null, .string(context.principal.id),
        .string(action), .string(collection + "/" + id), .string(Self.now()),
        undoOf.map(Value.string) ?? .null,
      ])
    let suffix =
      mutation.delete ? "deleted" : before == nil || before?.deleted == true ? "created" : "updated"
    let event = DomainEvent(
      id: UUID().uuidString.lowercased(), type: schema["type"]!.string! + "." + suffix,
      source: "agentos://data/" + collection, subject: collection + "/" + id, time: Self.now(),
      labels: labels, depth: context.depth, runID: context.runID,
      data: [
        "collection": .string(collection), "id": .string(id), "rev": .number(Double(rev)),
        "changedFields": .array(changed.sorted().map(Value.string)),
      ])
    try appendEvent(event)
    try audit(
      action, context: context,
      detail: [
        "effectID": .string(effectID), "collection": .string(collection), "id": .string(id),
        "rev": .number(Double(rev)),
      ])
    return MutationResult(record: after, effectID: effectID)
  }
  public func undo(_ effectID: String, context: RequestContext) throws -> MutationResult {
    guard
      let entry = try db.query("SELECT * FROM history WHERE effect_id=?", [.string(effectID)])
        .first,
      let effect = try db.query("SELECT * FROM effects WHERE id=?", [.string(effectID)]).first
    else { throw HostError("not_found", "No reversible data effect") }
    guard effect["state"]?.string == "applied" else {
      throw HostError("conflict", "Effect is already undone")
    }
    let collection = entry["collection"]!.string!
    let id = entry["id"]!.string!
    try require(context, capability: "data.write", scope: collection)
    return try db.transaction {
      let before = try entry["before"]?.string.map { try Value.parse($0).decode(Record.self) }
      let after = try Value.parse(entry["after"]!.string!).decode(Record.self)
      guard let current = try readRecord(collection, id: id) else {
        throw HostError("not_found", "Record missing")
      }
      let changed = Set(try Value.parse(entry["changed"]!.string!).array!.compactMap(\.string))
      let later = try db.query(
        "SELECT changed FROM history WHERE collection=? AND id=? AND rev>?",
        [.string(collection), .string(id), .number(Double(after.rev))])
      var conflicts = Set<String>()
      for row in later {
        let other = Set(try Value.parse(row["changed"]!.string!).array!.compactMap(\.string))
        if changed.contains("*") || other.contains("*") || changed.contains("$deleted")
          || other.contains("$deleted")
        {
          conflicts.formUnion(changed)
        } else {
          conflicts.formUnion(changed.intersection(other))
        }
      }
      guard conflicts.isEmpty else {
        throw HostError(
          "conflict", "Subsequent changes overlap; choose a resolution explicitly",
          details: [
            "fields": .array(conflicts.sorted().map(Value.string)),
            "before": try before.map(Value.from) ?? .null, "after": try Value.from(after),
            "current": try Value.from(current),
          ])
      }
      var fields = current.fields
      if before == nil {
        fields = current.fields
      } else if changed.contains("$deleted") {
        fields = before!.fields
      } else {
        for field in changed { fields[field] = before!.fields[field] }
      }
      let result = try apply(
        Mutation(
          collection, id: id, fields: fields, expectedRevision: current.rev,
          delete: before == nil || before!.deleted), context: context, undoOf: effectID,
        restoredLabels: before?.labels)
      for link in try db.query(
        "SELECT * FROM recovery_sources WHERE effect_id=?", [.string(effectID)])
      {
        guard
          try db.query("SELECT state FROM effects WHERE id=?", [link["source_id"]!]).first?["state"]
            == link["after_state"]
        else {
          throw HostError("conflict", "Grouped recovery source state changed")
        }
        try db.execute(
          "UPDATE effects SET state=? WHERE id=?", [link["before_state"]!, link["source_id"]!])
        try db.execute(
          "INSERT INTO recovery_sources VALUES (?,?,?,?)",
          [
            .string(result.effectID), link["source_id"]!, link["after_state"]!,
            link["before_state"]!,
          ])
      }
      try db.execute("UPDATE effects SET state='undone' WHERE id=?", [.string(effectID)])
      if let previous = effect["undo_of"]?.string {
        try db.execute("UPDATE effects SET state='applied' WHERE id=?", [.string(previous)])
      }
      return result
    }
  }
  public func history(_ collection: String, id: String, context: RequestContext) throws -> Value {
    try require(context, capability: "data.read", scope: collection)
    let rows = try db.query(
      "SELECT * FROM history WHERE collection=? AND id=? ORDER BY rev DESC",
      [.string(collection), .string(id)])
    // Historical private or tainted values carry labels too, even if current data is clean.
    for row in rows {
      try propagate(Value.parse(row["after"]!.string!).decode(Record.self).labels, to: context)
    }
    return .array(rows.map(Value.object))
  }
  public func activities(limit: Int = 100) throws -> [Activity] {
    try db.query(
      "SELECT * FROM effects ORDER BY seq DESC LIMIT ?", [.number(Double(min(max(1, limit), 1000)))]
    ).map { row in
      Activity(
        id: row["id"]!.string!, runID: row["run_id"]?.string, action: row["action"]!.string!,
        target: row["target"]!.string!, state: row["state"]!.string!,
        effect: EffectClass(rawValue: row["class"]!.string!)!, at: row["at"]!.string!,
        undoOf: row["undo_of"]?.string)
    }
  }
  func readRecord(_ collection: String, id: String) throws -> Record? {
    try db.query(
      "SELECT * FROM records WHERE collection=? AND id=?", [.string(collection), .string(id)]
    ).first.map(record)
  }
  func record(_ row: [String: Value]) throws -> Record {
    Record(
      collection: row["collection"]!.string!, id: row["id"]!.string!, rev: row["rev"]!.int!,
      fields: try Value.parse(row["fields"]!.string!).object!,
      labels: try Value.parse(row["labels"]!.string!).decode(Labels.self),
      deleted: row["deleted"]!.int == 1, createdBy: row["created_by"]?.string,
      createdAt: row["created_at"]?.string, updatedBy: row["updated_by"]?.string,
      updatedAt: row["updated_at"]?.string)
  }
  static func changedFields(_ before: Record?, _ after: Record) -> Set<String> {
    guard let before else { return ["*"] }
    var fields = Set(before.fields.keys).union(after.fields.keys).filter {
      before.fields[$0] != after.fields[$0]
    }
    if before.deleted != after.deleted { fields.insert("$deleted") }
    return fields
  }
  public func exportData() throws -> Value {
    [
      "schema": "agentos.export/1", "schemas": try schemas(),
      "records": .array(
        try db.query("SELECT * FROM records ORDER BY collection,id").map {
          try Value.from(record($0))
        }),
    ]
  }
}
