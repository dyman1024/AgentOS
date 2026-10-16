import Foundation

extension Value {
  public func requiredString(_ key: String) throws -> String {
    guard let s = self[key]?.string, !s.isEmpty else {
      throw HostError("invalid_args", "Missing string: \(key)")
    }
    return s
  }
  public func requiredInt(_ key: String) throws -> Int {
    guard let n = self[key]?.int else { throw HostError("invalid_args", "Missing integer: \(key)") }
    return n
  }
}
extension Kernel {
  public func schemaReferences() throws -> [String: Value] {
    var result: [String: Value] = [:]
    for row in try db.query(
      "SELECT s.type,v.definition,v.version FROM schemas s JOIN schema_versions v ON v.collection=s.collection"
    ) {
      let schema = try Value.parse(row["definition"]!.string!)
      let type = row["type"]!.string!
      let version = row["version"]!.int!
      result["agentos:schema/\(type)@\(version)"] = schema
      result["user:schema/\(type)@\(version)"] = schema
    }
    return result
  }
  public func tool(_ name: String) throws -> (InstalledApp, ToolDefinition) {
    let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { throw HostError("not_found", "Use namespace.tool") }
    let item = try app(parts[0])
    guard item.version != "draft",
      let tool = try AppInterface(item.interface).tools.first(where: { $0.name == parts[1] })
    else { throw HostError("not_found", "Tool is unavailable") }
    return (item, tool)
  }
  public func describe(_ args: Value) throws -> Value {
    if let name = args["tool"]?.string {
      let (app, tool) = try tool(name)
      return [
        "name": .string(name), "description": .string(tool.description), "input": tool.input,
        "output": tool.output, "examples": .array(tool.examples),
        "effectCeiling": .string(try effectCeiling(app.id).rawValue),
      ]
    }
    let item = try app(args.requiredString("app"))
    let directory =
      item.version == "draft" ? try sourceDirectory(item.id) : try activeDirectory(item.id)
    return [
      "app": try Value.from(item),
      "skill": .string(
        String(
          (try String(contentsOf: SafePath.resolve("SKILL.md", under: directory), encoding: .utf8))
            .prefix(12000))),
    ]
  }
  public func effectCeiling(_ id: String) throws -> EffectClass {
    let caps = try db.query(
      "SELECT capability,scope FROM grants WHERE holder=? AND revoked=0 AND (expires IS NULL OR expires>?)",
      [.string(Principal.core(id).id), .number(Date().timeIntervalSince1970)])
    if caps.contains(where: {
      ["service", "call", "net", "files"].contains($0["capability"]?.string ?? "")
    }) {
      return .irreversible
    }
    if caps.contains(where: { $0["capability"]?.string == "data.write" }) { return .write }
    return .read
  }
  // Shared data/package surface. Runtime, Agent, and CLI call this with a host-bound context.
  public func route(_ method: String, args: Value, context: RequestContext) throws -> Value {
    switch method {
    case "data.schemas":
      try require(context, capability: "data.read", scope: args["collection"]?.string ?? "*")
      return try schemas()
    case "data.previewGroupRecovery":
      return try prepareGroupRecovery(args, context: context).summary
    case "data.recoveryGroups":
      return try recoveryGroups(context: context)
    case "data.previewMigration":
      return try prepareMigration(args, context: context).summary
    case "data.get":
      return try get(
        args.requiredString("collection"), id: args.requiredString("id"), context: context
      ).value
    case "data.query":
      if let semantic = args["semantic"]?.string {
        return try semanticQuery(
          args.requiredString("collection"), text: semantic, filters: args["where"]?.object ?? [:],
          limit: args["limit"]?.int ?? 20, context: context)
      }
      return .array(
        try query(
          args.requiredString("collection"), text: args["text"]?.string ?? "",
          where: args["where"]?.object ?? [:], orderBy: args["orderBy"]?.string ?? "_id",
          limit: args["limit"]?.int ?? 100, context: context
        ).map(\.value))
    case "data.put":
      let fields = args["record"]?.object ?? args["fields"]?.object ?? [:]
      let metadata: Set<String> = [
        "_id", "_rev", "_labels", "_createdAt", "_updatedAt", "_createdBy", "_updatedBy",
      ]
      let result = try put(
        args.requiredString("collection"), id: args["id"]?.string ?? fields["_id"]?.string,
        fields: fields.filter { !metadata.contains($0.key) },
        expectedRevision: args["rev"]?.int ?? fields["_rev"]?.int, context: context)
      return result.record.value
    case "data.delete":
      return try delete(
        args.requiredString("collection"), id: args.requiredString("id"),
        expectedRevision: args.requiredInt("rev"), context: context
      ).record.value
    case "data.history":
      return try history(
        args.requiredString("collection"), id: args.requiredString("id"), context: context)
    case "data.restore":
      return try undo(args.requiredString("effectID"), context: context).record.value
    case "data.registerSchema":
      try registerSchema(
        collection: args.requiredString("collection"), type: args.requiredString("type"),
        definition: args["definition"] ?? .null, isPrivate: args["private"]?.bool ?? false,
        context: context)
      return ["ok": true]
    case "apps.list":
      try require(context, capability: "apps.discover", scope: "*")
      let apps = try installedApps()
      for app in apps { try propagate(packageLabels(app.id), to: context) }
      return try Value.from(apps)
    case "apps.search":
      try require(context, capability: "apps.discover", scope: "*")
      let found = try searchTools(args["query"]?.string ?? "", limit: args["limit"]?.int ?? 20)
      for item in found.array ?? [] {
        if let id = item["appID"]?.string { try propagate(packageLabels(id), to: context) }
      }
      return found
    case "apps.describe":
      try require(context, capability: "apps.discover", scope: "*")
      let item = try args["tool"]?.string.map { try tool($0).0 } ?? app(args.requiredString("app"))
      try propagate(packageLabels(item.id), to: context)
      return try describe(args)
    case "apps.create":
      return try Value.from(
        createApp(
          title: args.requiredString("title"), namespace: args["namespace"]?.string ?? "app",
          context: context))
    case "apps.diff":
      return try packageDiff(
        args.requiredString("app"), from: args.requiredString("from"),
        to: args["to"]?.string ?? "draft", context: context)
    case "apps.versions":
      try require(context, capability: "app.read", scope: args.requiredString("app"))
      return .array(try versions(args.requiredString("app")).map(Value.string))
    case "apps.rollback":
      try rollback(
        args.requiredString("app"), version: args.requiredString("version"), context: context)
      return ["ok": true]
    case "apps.remove":
      try removeApp(args.requiredString("app"), context: context)
      return ["ok": true]
    case "workspace.read", "workspace.write", "workspace.list", "workspace.remove":
      return try workspace(method, args: args, context: context)
    case "events.list":
      try require(context, capability: "events.inspect", scope: "*")
      return try events(
        after: args["after"]?.int ?? 0, pattern: args["pattern"]?.string ?? "*",
        limit: args["limit"]?.int ?? 100)
    case "activity.details":
      return try activityDetails(args.requiredString("id"), context: context)
    case "activity.list":
      try require(context, capability: "activity.read", scope: "*")
      return try Value.from(activities())
    default: throw HostError("not_found", "Unknown host method: \(method)")
    }
  }
  public func removeApp(_ id: String, context: RequestContext) throws {
    try require(context, capability: "app.remove", scope: id)
    let item = try app(id)
    try db.transaction {
      try db.execute(
        "UPDATE grants SET revoked=1 WHERE holder=?", [.string(Principal.core(item.id).id)])
      try db.execute(
        "UPDATE subscriptions SET paused=1 WHERE holder=?", [.string(Principal.core(item.id).id)])
      try db.execute("DELETE FROM packages WHERE id=?", [.string(item.id)])
      try audit(
        "app.removed", context: context, detail: ["app": .string(item.id), "dataRetained": true])
    }
    // Keep code in the recovery area until the user explicitly clears it; shared data is independent.
  }
  public func workspace(_ method: String, args: Value, context: RequestContext) throws -> Value {
    let id = try args.requiredString("app")
    try require(
      context,
      capability: method == "workspace.read" || method == "workspace.list"
        ? "app.read" : "app.edit", scope: id)
    let item = try app(id)
    let directory = try sourceDirectory(item.id)
    try propagate(packageLabels(item.id), to: context)
    if method == "workspace.write" || method == "workspace.remove" {
      try labelPackage(item.id, with: labels(for: context))
    }
    let fm = FileManager.default
    if method == "workspace.list" {
      guard let enumerator = fm.enumerator(atPath: directory.path) else {
        throw HostError("not_found", "Workspace missing")
      }
      var files: [Value] = []
      for case let name as String in enumerator {
        if name.split(separator: "/").contains(".git") {
          enumerator.skipDescendants()
          continue
        }
        let file = try SafePath.resolve(name, under: directory)
        if (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
          files.append(.string(name))
        }
      }
      return .array(files)
    }
    let path = try SafePath.resolve(
      args.requiredString("path"), under: directory, mustExist: method != "workspace.write")
    if method == "workspace.read" {
      let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= 2_000_000 else { throw HostError("invalid_args", "File exceeds text limit") }
      return ["content": .string(try String(contentsOf: path, encoding: .utf8))]
    }
    if method == "workspace.remove" {
      try fm.removeItem(at: path)
    } else {
      let bytes: Data
      if let encoded = args["base64"]?.string {
        guard args["content"] == nil, let decoded = Data(base64Encoded: encoded),
          decoded.count <= 2_000_000
        else { throw HostError("invalid_args", "Provide valid base64 up to 2 MB, without content") }
        bytes = decoded
      } else {
        guard let content = args["content"]?.string, content.utf8.count <= 2_000_000 else {
          throw HostError("invalid_args", "Provide UTF-8 content up to 2 MB")
        }
        bytes = Data(content.utf8)
      }
      try fm.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bytes.write(to: path, options: .atomic)
    }
    try audit(
      method, context: context, detail: ["app": .string(id), "path": args["path"] ?? .null])
    return ["ok": true]
  }
}
