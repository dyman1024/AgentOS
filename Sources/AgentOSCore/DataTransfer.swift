import Foundation

extension Kernel {
  /// This is a host settings operation, not an application RPC. Existing records are never replaced.
  public func importData(_ archive: Value, issuer: Principal = .user) throws -> Value {
    guard issuer == .user else { throw HostError("denied", "Data import requires user controls") }
    guard archive["schema"] == "agentos.export/1", let schemas = archive["schemas"]?.array,
      schemas.count <= 1000, let values = archive["records"]?.array, values.count <= 100000,
      try archive.encoded().count <= 100_000_000
    else { throw HostError("invalid_args", "Invalid or oversized data archive") }
    let records = try values.map { try $0.decode(Record.self) }
    let digest = Self.digest(try archive.encoded())
    let context = RequestContext(.user)
    return try db.transaction {
      for schema in schemas {
        try registerSchema(
          collection: schema.requiredString("collection"), type: schema.requiredString("type"),
          definition: Value.parse(schema.requiredString("definition")),
          isPrivate: schema["private"]?.int == 1, version: schema["version"]?.int ?? 1,
          context: context)
      }
      var count = 0
      for record in records {
        guard try readRecord(record.collection, id: record.id) == nil else {
          throw HostError(
            "conflict", "Import would replace an existing record: \(record.collection)/\(record.id)"
          )
        }
        let labels = record.labels.union(Labels(taint: ["import:" + digest]))
        let created = try apply(
          Mutation(record.collection, id: record.id, fields: record.fields), context: context,
          restoredLabels: labels)
        if record.deleted {
          _ = try apply(
            Mutation(
              record.collection, id: record.id, expectedRevision: created.record.rev, delete: true),
            context: context, restoredLabels: labels)
        }
        count += 1
      }
      try audit(
        "data.imported", context: context,
        detail: ["records": .number(Double(count)), "digest": .string(digest)])
      return ["records": .number(Double(count)), "digest": .string(digest)]
    }
  }
  /// Atomic JSON snapshot remains readable without this build of AgentOS.
  public func backupData() throws -> String {
    let folder = root.appendingPathComponent("system/backups")
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let id = UUID().uuidString.lowercased()
    let file = folder.appendingPathComponent(id + ".json")
    try exportData().encoded().write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try audit("data.backup", context: RequestContext(.user), detail: ["id": .string(id)])
    return id
  }
}
