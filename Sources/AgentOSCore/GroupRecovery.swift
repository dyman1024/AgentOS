import Foundation

/// A sealed preview, never accepted as JSON evidence from applications or the CLI.
public struct PreparedGroupRecovery: Sendable {
  public let selection: Value
  public let summary: Value
  let digest: String
  let targets: [Record]
  let effects: [String]
}

extension Kernel {
  /// App attribution means the executing core, or direct writes by a run initiated by that app.
  /// Run attribution includes every core called with that run ID. External effects are listed only.
  public func prepareGroupRecovery(_ selection: Value, context: RequestContext) throws
    -> PreparedGroupRecovery
  {
    try require(context, capability: "data.restoreGroup", scope: "*")
    let kind = try selection.requiredString("kind")
    let id = try selection.requiredString("id")
    var parameters: [Value]
    var predicate: String
    switch kind {
    case "app":
      guard UUID(uuidString: id) != nil else {
        throw HostError("invalid_args", "Use an application ID")
      }
      predicate = "(e.principal=? OR (e.principal LIKE 'run:%' AND r.initiator=?))"
      parameters = [
        .string(Principal.core(id).id), .string(try Value.from(Principal.core(id)).text()),
      ]
    case "run":
      guard try db.query("SELECT id FROM runs WHERE id=?", [.string(id)]).first != nil else {
        throw HostError("not_found", "Unknown run")
      }
      predicate = "e.run_id=?"
      parameters = [.string(id)]
    default: throw HostError("invalid_args", "Recovery kind must be app or run")
    }
    if let at = selection["after"]?.string {
      guard let date = ISO8601DateFormatter().date(from: at), date <= Date() else {
        throw HostError("invalid_args", "Invalid recovery time")
      }
      predicate += " AND e.at>?"
      parameters.append(.string(ISO8601DateFormatter().string(from: date)))
    }
    let rows = try db.query(
      """
      SELECT e.*,h.collection,h.id AS record_id,h.before,h.after,h.changed,h.seq AS history_seq
      FROM effects e LEFT JOIN history h ON h.effect_id=e.id LEFT JOIN runs r ON r.id=e.run_id
      WHERE \(predicate) ORDER BY e.seq DESC LIMIT 1001
      """, parameters)
    guard rows.count <= 1000 else {
      throw HostError("too_large", "Narrow the recovery time; at most 1000 effects")
    }
    let selected = rows.filter { $0["history_seq"]?.int != nil && $0["state"] == "applied" }
    let effectIDs = Set(selected.compactMap { $0["id"]?.string })
    let collections = Set(selected.compactMap { $0["collection"]?.string }).sorted()
    var snapshots: [Value] = []
    for collection in collections {
      try require(context, capability: "data.read", scope: collection)
      try require(context, capability: "data.write", scope: collection)
      snapshots.append(try collectionSnapshot(collection))
    }
    var targets: [Record] = []
    var previews: [Value] = []
    var conflicts: [Value] = []
    let groups = Dictionary(grouping: selected) {
      $0["collection"]!.string! + "/" + $0["record_id"]!.string!
    }
    for key in groups.keys.sorted() {
      let entries = groups[key]!
      let collection = entries[0]["collection"]!.string!
      let recordID = entries[0]["record_id"]!.string!
      guard let current = try readRecord(collection, id: recordID) else {
        throw HostError("conflict", "Recovery record disappeared")
      }
      let firstSequence = entries.compactMap { $0["history_seq"]?.int }.min()!
      let history = try db.query(
        "SELECT * FROM history WHERE collection=? AND id=? AND seq>=? ORDER BY seq DESC LIMIT 10001",
        [.string(collection), .string(recordID), .number(Double(firstSequence))])
      guard history.count <= 10000 else {
        throw HostError("too_large", "Record history exceeds recovery limit")
      }
      var fields = current.fields
      var deleted = current.deleted
      var labels = current.labels
      var protected = Set<String>()
      var overlap = Set<String>()
      for entry in history {
        let changed = Set(try Value.parse(entry["changed"]!.string!).array!.compactMap(\.string))
        if !effectIDs.contains(entry["effect_id"]!.string!) {
          protected.formUnion(changed)
          continue
        }
        let before = try entry["before"]?.string.map { try Value.parse($0).decode(Record.self) }
        let after = try Value.parse(entry["after"]!.string!).decode(Record.self)
        labels = labels.union(after.labels).union(before?.labels ?? Labels())
        if !protected.isEmpty
          && (!changed.isDisjoint(with: ["*", "$deleted"])
            || !protected.isDisjoint(with: ["*", "$deleted"]))
        {
          overlap.formUnion(changed)
        } else {
          overlap.formUnion(changed.intersection(protected))
        }
        if let before {
          if changed.contains("$deleted") {
            fields = before.fields
            deleted = before.deleted
          } else {
            for field in changed { fields[field] = before.fields[field] }
          }
        } else {
          deleted = true
        }
      }
      try propagate(labels, to: context)
      let schema = try db.query(
        "SELECT definition FROM schemas WHERE collection=?", [.string(collection)])[0]
      do {
        try Schema.validate(.object(fields), against: Value.parse(schema["definition"]!.string!))
      } catch { overlap.insert("$schema") }
      if !overlap.isEmpty {
        conflicts.append([
          "collection": .string(collection), "id": .string(recordID),
          "fields": .array(overlap.sorted().map(Value.string)),
        ])
      }
      let target = Record(
        collection: collection, id: recordID, rev: current.rev, fields: fields,
        labels: labels, deleted: deleted, createdBy: current.createdBy,
        createdAt: current.createdAt,
        updatedBy: current.updatedBy, updatedAt: current.updatedAt)
      targets.append(target)
      previews.append([
        "collection": .string(collection), "id": .string(recordID),
        "before": current.value, "after": target.value, "deletedAfter": .bool(deleted),
      ])
    }
    let evidence: Value = [
      "effects": .array(rows.map(Value.object)), "collections": .array(snapshots),
    ]
    guard try evidence.encoded().count <= 50_000_000 else {
      throw HostError("too_large", "Recovery preview exceeds 50 MB")
    }
    let excluded = rows.filter { !effectIDs.contains($0["id"]!.string!) }.map { row -> Value in
      [
        "id": row["id"]!, "action": row["action"]!, "state": row["state"]!,
        "reason": row["history_seq"]?.int == nil ? "非共享数据操作，未恢复" : "已撤销，未重复恢复",
      ]
    }
    try propagate(Labels(isPrivate: true), to: context)
    return PreparedGroupRecovery(
      selection: selection,
      summary: [
        "selection": selection, "effects": .number(Double(effectIDs.count)),
        "records": .array(previews), "conflicts": .array(conflicts), "excluded": .array(excluded),
        "canApply": .bool(!targets.isEmpty && conflicts.isEmpty),
      ], digest: Self.digest(try evidence.encoded()), targets: targets, effects: effectIDs.sorted())
  }

  public func applyGroupRecovery(
    _ prepared: PreparedGroupRecovery, approved: Bool, context: RequestContext
  ) throws -> Value {
    let fresh = try prepareGroupRecovery(prepared.selection, context: context)
    guard fresh.digest == prepared.digest else {
      throw HostError("conflict", "Recovery preview changed; preview again")
    }
    guard fresh.summary["canApply"] == true else {
      throw HostError(
        "conflict", "Recovery is empty or overlaps later writes", details: fresh.summary)
    }
    guard approved else {
      throw HostError(
        "needs_confirmation", "Group recovery requires host approval", details: fresh.summary)
    }
    let backup = try backupData()
    let group = UUID().uuidString.lowercased()
    return try db.transaction {
      var results: [Value] = []
      for target in fresh.targets {
        let result = try apply(
          Mutation(
            target.collection, id: target.id, fields: target.fields,
            expectedRevision: target.rev, delete: target.deleted), context: context,
          undoOf: "group:" + group, restoredLabels: target.labels, restoreDeletedFields: true)
        for id in fresh.effects {
          if try db.query(
            "SELECT effect_id FROM history WHERE effect_id=? AND collection=? AND id=?",
            [.string(id), .string(target.collection), .string(target.id)]
          ).first != nil {
            try db.execute(
              "INSERT INTO recovery_sources VALUES (?,?,'applied','undone')",
              [.string(result.effectID), .string(id)])
          }
        }
        results.append(result.record.value)
        try db.execute(
          "DELETE FROM embeddings WHERE collection=? AND id=?",
          [.string(target.collection), .string(target.id)])
      }
      for id in fresh.effects {
        try db.execute("UPDATE effects SET state='undone' WHERE id=?", [.string(id)])
      }
      try audit(
        "data.groupRestored", context: context,
        detail: [
          "group": .string(group),
          "backup": .string(backup), "selection": fresh.selection,
          "effects": .array(fresh.effects.map(Value.string)),
        ])
      return ["group": .string(group), "backup": .string(backup), "records": .array(results)]
    }
  }
}

extension Kernel {
  public func recoveryGroups(context: RequestContext) throws -> Value {
    try require(context, capability: "activity.read", scope: "*")
    try propagate(Labels(isPrivate: true), to: context)
    var apps: [Value] = []
    for row in try db.query(
      "SELECT principal,MAX(seq) AS latest FROM effects WHERE principal LIKE 'app:%/core' GROUP BY principal ORDER BY latest DESC LIMIT 1000"
    ) {
      let principal = row["principal"]!.string!
      let id = String(principal.dropFirst(4).dropLast(5))
      apps.append(["id": .string(id), "title": .string((try? app(id).title) ?? id)])
    }
    // Include apps whose only writes were made by their delegated runs.
    for row in try db.query(
      "SELECT DISTINCT r.initiator FROM runs r JOIN effects e ON e.run_id=r.id LIMIT 1001")
    {
      if let id = try Value.parse(row["initiator"]!.string!).decode(Principal.self).appID,
        !apps.contains(where: { $0["id"] == .string(id) })
      {
        apps.append(["id": .string(id), "title": .string((try? app(id).title) ?? id)])
      }
    }
    return ["apps": .array(apps), "runs": try runs(limit: 1000)]
  }
}
