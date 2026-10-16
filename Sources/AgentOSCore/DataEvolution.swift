import Foundation

/// Host-prepared evidence is bound to every current record revision and the schema version.
public struct PreparedDataChange: Sendable {
  public let collection: String
  public let definition: Value
  public let baseDigest: String
  public let records: [Record]
  public let summary: Value
}

extension Kernel {
  func collectionSnapshot(_ collection: String) throws -> Value {
    guard
      let schema = try schemas().array?.first(where: { $0["collection"] == .string(collection) })
    else { throw HostError("not_found", "Unknown collection") }
    let records = try db.query(
      "SELECT * FROM records WHERE collection=? ORDER BY id", [.string(collection)])
    guard records.count <= 10000 else {
      throw HostError("too_large", "A data change supports up to 10000 records")
    }
    let snapshot: Value = [
      "schema": schema, "records": .array(try records.map { try Value.from(record($0)) }),
    ]
    guard try snapshot.encoded().count <= 50_000_000 else {
      throw HostError("too_large", "Collection exceeds 50 MB")
    }
    return snapshot
  }

  /// Declarative, deterministic field operations; no generated code runs inside the kernel.
  public func prepareMigration(_ plan: Value, excludingApp: String? = nil, context: RequestContext)
    throws -> PreparedDataChange
  {
    try prepareMigration(
      plan, excludingApps: Set(excludingApp.map { [$0] } ?? []), context: context)
  }

  func prepareMigration(
    _ plan: Value, excludingApps excludedApps: Set<String>, context: RequestContext
  ) throws -> PreparedDataChange {
    let collection = try plan.requiredString("collection")
    try require(context, capability: "schemas.migrate", scope: collection)
    guard plan["schema"] == "agentos.migration/1",
      !SystemSchemas.entries.contains(where: { $0.0 == collection }),
      let definition = plan["definition"], let steps = plan["steps"]?.array, steps.count <= 100
    else {
      throw HostError("invalid_schema", "Only explicit user-schema migration plans are supported")
    }
    try Schema.lint(definition)
    guard definition["type"] == "object" else {
      throw HostError("invalid_schema", "Record schema must be an object")
    }
    let before = try collectionSnapshot(collection)
    let version = before["schema"]!["version"]!.int!
    guard plan["fromVersion"]?.int == version, plan["toVersion"]?.int == version + 1 else {
      throw HostError("conflict", "Schema version changed or target is not the next version")
    }
    try requireNoDataDependents(collection, excludingApps: excludedApps)
    let records = try before["records"]!.array!.map { value -> Record in
      let old = try value.decode(Record.self)
      var fields = old.fields
      for step in steps {
        let operation = try step.requiredString("op")
        let field = try step.requiredString(operation == "rename" ? "from" : "field")
        guard !field.hasPrefix("_"), field.count <= 128 else {
          throw HostError("invalid_args", "Reserved or oversized field")
        }
        switch operation {
        case "rename":
          let target = try step.requiredString("to")
          guard !target.hasPrefix("_"), target.count <= 128, target != field else {
            throw HostError("invalid_args", "Invalid rename target")
          }
          if let value = fields[field] {
            guard fields[target] == nil else {
              throw HostError("conflict", "Rename would overwrite a field")
            }
            fields[target] = value
            fields[field] = nil
          }
        case "default":
          guard let value = step["value"] else {
            throw HostError("invalid_args", "Missing default value")
          }
          if fields[field] == nil { fields[field] = value }
        case "remove": fields[field] = nil
        default: throw HostError("invalid_args", "Unknown migration operation")
        }
      }
      try Schema.validate(.object(fields), against: definition)
      return Record(
        collection: collection, id: old.id, rev: old.rev, fields: fields, labels: old.labels,
        deleted: old.deleted,
        createdBy: old.createdBy, createdAt: old.createdAt, updatedBy: old.updatedBy,
        updatedAt: old.updatedAt)
    }
    // Validate operation shapes even when the collection is empty.
    for step in steps {
      guard let op = step["op"]?.string, ["rename", "default", "remove"].contains(op),
        let field = step[op == "rename" ? "from" : "field"]?.string, !field.isEmpty,
        !field.hasPrefix("_"), field.count <= 128,
        op != "rename"
          || (step["to"]?.string.map {
            !$0.isEmpty && !$0.hasPrefix("_") && $0.count <= 128 && $0 != field
          } == true),
        op != "default" || step["value"] != nil
      else { throw HostError("invalid_args", "Malformed migration operation") }
    }
    return PreparedDataChange(
      collection: collection, definition: definition,
      baseDigest: Self.digest(try before.encoded()), records: records,
      summary: [
        "collection": .string(collection), "fromVersion": .number(Double(version)),
        "toVersion": .number(Double(version + 1)), "records": .number(Double(records.count)),
        "steps": .array(steps),
      ])
  }

  func requireNoDataDependents(_ collection: String, excludingApps: Set<String>) throws {
    let dependents = try installedApps().filter {
      $0.version != "draft" && !excludingApps.contains($0.id)
        && (try? AppInterface($0.interface).data[collection]) != nil
    }
    guard dependents.isEmpty else {
      throw HostError(
        "conflict", "Shared schema has other installed dependents; migrate their interfaces first",
        details: .array(dependents.map { .string($0.namespace) }))
    }
  }

  /// Restore a collection from a host backup. Later writes invalidate this preview.
  public func prepareCollectionRestore(
    _ collection: String, backupID: String, context: RequestContext
  ) throws -> PreparedDataChange {
    try require(context, capability: "data.restoreCollection", scope: collection)
    guard UUID(uuidString: backupID) != nil else {
      throw HostError("invalid_args", "Invalid backup ID")
    }
    let file = root.appendingPathComponent("system/backups/" + backupID + ".json")
    guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= 100_000_000 else {
      throw HostError("too_large", "Backup exceeds 100 MB")
    }
    let archive = try Value.parse(String(contentsOf: file, encoding: .utf8))
    guard archive["schema"] == "agentos.export/1",
      let schema = archive["schemas"]?.array?.first(where: {
        $0["collection"] == .string(collection)
      })
    else { throw HostError("invalid_args", "Collection is not in this backup") }
    let before = try collectionSnapshot(collection)
    let definition = try Value.parse(schema.requiredString("definition"))
    try Schema.lint(definition)
    let records = try (archive["records"]?.array ?? []).map { try $0.decode(Record.self) }.filter {
      $0.collection == collection
    }
    guard records.count <= 10000, Set(records.map(\.id)).count == records.count else {
      throw HostError("invalid_args", "Oversized or duplicate collection records")
    }
    for record in records { try Schema.validate(.object(record.fields), against: definition) }
    return PreparedDataChange(
      collection: collection, definition: definition,
      baseDigest: Self.digest(try before.encoded()), records: records,
      summary: [
        "collection": .string(collection), "backup": .string(backupID),
        "records": .number(Double(records.count)),
      ])
  }

  public func dataBackups() throws -> Value {
    let folder = root.appendingPathComponent("system/backups")
    guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
    let entries = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
    )
    .filter {
      $0.pathExtension == "json"
        && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return .array(
      try entries.map { file in
        let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return [
          "id": .string(file.deletingPathExtension().lastPathComponent),
          "at": .string(
            ISO8601DateFormatter().string(from: values.contentModificationDate ?? .distantPast)),
          "bytes": .number(Double(values.fileSize ?? 0)),
        ]
      }.sorted { ($0["at"]?.string ?? "") > ($1["at"]?.string ?? "") })
  }

  public func prepareTimepointRestore(_ collection: String, at: String, context: RequestContext)
    throws -> PreparedDataChange
  {
    try require(context, capability: "data.restoreCollection", scope: collection)
    guard let date = ISO8601DateFormatter().date(from: at), date <= Date() else {
      throw HostError("invalid_args", "Choose an ISO8601 time in the past")
    }
    let normalized = ISO8601DateFormatter().string(from: date)
    let before = try collectionSnapshot(collection)
    let definition = try Value.parse(before["schema"]!.requiredString("definition"))
    let entries = try db.query(
      "SELECT h.after FROM history h JOIN (SELECT h2.id,MAX(h2.seq) AS seq FROM history h2 JOIN effects e ON e.id=h2.effect_id WHERE h2.collection=? AND e.at<=? GROUP BY h2.id LIMIT 10001) chosen ON h.seq=chosen.seq ORDER BY h.id",
      [.string(collection), .string(normalized)])
    var records: [String: Record] = [:]
    for row in entries {
      let record = try Value.parse(row["after"]!.string!).decode(Record.self)
      records[record.id] = record
    }
    guard records.count <= 10000 else {
      throw HostError("too_large", "Restore supports up to 10000 records")
    }
    for record in records.values {
      try Schema.validate(.object(record.fields), against: definition)
    }
    return PreparedDataChange(
      collection: collection, definition: definition,
      baseDigest: Self.digest(try before.encoded()),
      records: records.values.sorted { $0.id < $1.id },
      summary: [
        "collection": .string(collection), "restoreAt": .string(normalized),
        "records": .number(Double(records.count)),
        "currentRecords": .number(Double(before["records"]!.array!.count)),
      ])
  }

  public func applyDataChange(_ change: PreparedDataChange, approved: Bool, context: RequestContext)
    throws -> Value
  {
    let capability =
      change.summary["fromVersion"] != nil ? "schemas.migrate" : "data.restoreCollection"
    try require(context, capability: capability, scope: change.collection)
    if change.summary["fromVersion"] != nil {
      try requireNoDataDependents(change.collection, excludingApps: [])
    }
    guard approved else {
      throw HostError(
        "needs_confirmation", "Review the complete data change", details: change.summary)
    }
    let before = try collectionSnapshot(change.collection)
    guard Self.digest(try before.encoded()) == change.baseDigest else {
      throw HostError("conflict", "Collection changed after preview")
    }
    let backup = try backupData()
    return try db.transaction {
      try installDataChange(change, context: context)
      try audit(
        "data.collectionChanged", context: context,
        detail: ["backup": .string(backup), "change": change.summary])
      return ["backup": .string(backup), "change": change.summary]
    }
  }

  /// Caller owns the outer transaction, backup and approval; used by atomic package activation.
  func installDataChange(_ change: PreparedDataChange, context: RequestContext) throws {
    let before = try collectionSnapshot(change.collection)
    guard Self.digest(try before.encoded()) == change.baseDigest else {
      throw HostError("conflict", "Collection changed after preview")
    }
    let existingDefinition = try Value.parse(before["schema"]!.requiredString("definition"))
    if change.summary["fromVersion"] != nil || change.definition != existingDefinition {
      let version = before["schema"]!["version"]!.int! + 1
      try db.execute(
        "UPDATE schemas SET definition=? WHERE collection=?",
        [.string(try change.definition.text()), .string(change.collection)])
      try db.execute(
        "INSERT INTO schema_versions VALUES (?,?,?)",
        [
          .string(change.collection), .number(Double(version)),
          .string(try change.definition.text()),
        ])
    }
    let current = try before["records"]!.array!.map { try $0.decode(Record.self) }
    let target = Dictionary(uniqueKeysWithValues: change.records.map { ($0.id, $0) })
    for old in current where target[old.id] == nil && !old.deleted {
      _ = try apply(
        Mutation(change.collection, id: old.id, expectedRevision: old.rev, delete: true),
        context: context, undoOf: "collection-change")
    }
    for desired in change.records {
      let old = try readRecord(change.collection, id: desired.id)
      if old?.fields == desired.fields && old?.deleted == desired.deleted { continue }
      // A tombstone must carry the transformed fields too; preserve its deleted state in a second write.
      let written = try apply(
        Mutation(
          change.collection, id: desired.id, fields: desired.fields, expectedRevision: old?.rev),
        context: context, undoOf: "collection-change", restoredLabels: desired.labels)
      if desired.deleted {
        _ = try apply(
          Mutation(
            change.collection, id: desired.id, expectedRevision: written.record.rev, delete: true),
          context: context, undoOf: "collection-change", restoredLabels: desired.labels)
      }
    }
    try db.execute("DELETE FROM embeddings WHERE collection=?", [.string(change.collection)])
  }
}
