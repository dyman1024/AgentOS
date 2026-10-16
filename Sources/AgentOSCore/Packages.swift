import Foundation

public struct InstalledApp: Codable, Sendable, Identifiable {
  public let id: String
  public let namespace: String
  public let version: String
  public let manifest: Value
  public let interface: Value
  public init(id: String, namespace: String, version: String, manifest: Value, interface: Value) {
    self.id = id
    self.namespace = namespace
    self.version = version
    self.manifest = manifest
    self.interface = interface
  }
  public var title: String { manifest["title"]?.string ?? namespace }
  public var icon: String { manifest["icon"]?.string ?? "square.grid.2x2" }
}
public struct PreparedPackage: Sendable {
  public let appID: String
  public let version: String
  public let baseVersion: String
  public let directory: URL
  public let manifest: Value
  public let interface: AppInterface
  public let digest: String
  public let migration: PreparedDataChange?
  public let interfaceChanges: [String]
}
public enum SafePath {
  public static func resolve(_ relative: String, under root: URL, mustExist: Bool = true) throws
    -> URL
  {
    guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
      !relative.contains("\0"),
      !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
        $0 == ".." || $0 == ".git"
      })
    else { throw HostError("denied", "Path escapes application root") }
    let base = root.resolvingSymlinksInPath().standardizedFileURL
    let url = base.appendingPathComponent(relative).standardizedFileURL
    let resolved = url.resolvingSymlinksInPath()
    guard resolved.path.hasPrefix(base.path + "/") else {
      throw HostError("denied", "Symlink escapes application root")
    }
    if mustExist, !FileManager.default.fileExists(atPath: resolved.path) {
      throw HostError("not_found", "File does not exist")
    }
    return resolved
  }
}
extension Kernel {
  public func createApp(title: String, namespace requested: String = "app", context: RequestContext)
    throws -> InstalledApp
  {
    try require(context, capability: "app.create", scope: "*")
    guard Self.validName(requested) else { throw HostError("invalid_args", "Invalid namespace") }
    let reserved = ["data", "apps", "events", "system", "automation", "vm", "ext"]
    guard !reserved.contains(requested) else {
      throw HostError("invalid_args", "Reserved namespace")
    }
    let used = try installedApps().map(\.namespace)
    var namespace = requested
    var index = 2
    while used.contains(namespace) {
      namespace = requested + "-\(index)"
      index += 1
    }
    let id = UUID().uuidString.lowercased()
    let directory = root.appendingPathComponent("apps/\(id)/src")
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("interface"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("ui"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("tests"), withIntermediateDirectories: true)
    let manifest: Value = [
      "schema": "agentos.app/1", "id": .string(id), "version": "1.0.0+1", "title": .string(title),
      "icon": "square.grid.2x2",
      "runtime": ["kind": "web", "core": "core.js", "ui": "ui/index.html", "minHost": "26.0"],
      "permissions": ["network": [], "services": [], "files": []],
    ]
    let interface: Value = [
      "schema": "agentos.interface/1", "id": .string(namespace), "version": "1.0.0",
      "summary": .string(title), "tools": [], "data": [], "calls": [], "subscribes": [],
    ]
    try manifest.encoded().write(
      to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    try interface.encoded().write(
      to: directory.appendingPathComponent("interface/interface.json"), options: .atomic)
    try Data("// Register tool handlers declared in interface/interface.json.\n".utf8).write(
      to: directory.appendingPathComponent("core.js"))
    try Data(
      "<!doctype html><meta charset=\"utf-8\"><style>body{background:#08080a;color:#f2efe9;font:16px system-ui;display:grid;place-items:center;height:90vh}</style><p>正在生长</p>"
        .utf8
    ).write(to: directory.appendingPathComponent("ui/index.html"))
    try Data("[]".utf8).write(to: directory.appendingPathComponent("tests/contract.json"))
    try Data("# \(title)\n\n应用规格待 Builder 完成。\n".utf8).write(
      to: directory.appendingPathComponent("SPEC.md"))
    try Data("# \(title)\n\n工具以 interface/interface.json 为准。\n".utf8).write(
      to: directory.appendingPathComponent("SKILL.md"))
    try Self.git(["init", "--quiet"], directory: directory)
    try db.execute(
      "INSERT INTO packages VALUES (?,?,?, ?,?)",
      [
        .string(id), .string(namespace), .string("draft"), .string(try manifest.text()),
        .string(try interface.text()),
      ])
    try labelPackage(id, with: labels(for: context))
    try audit("app.created", context: context, detail: ["appID": .string(id)])
    return InstalledApp(
      id: id, namespace: namespace, version: "draft", manifest: manifest, interface: interface)
  }
  public func installedApps() throws -> [InstalledApp] {
    try db.query("SELECT * FROM packages ORDER BY namespace").map { row in
      InstalledApp(
        id: row["id"]!.string!, namespace: row["namespace"]!.string!,
        version: row["version"]!.string!, manifest: try Value.parse(row["manifest"]!.string!),
        interface: try Value.parse(row["interface"]!.string!))
    }
  }
  public func app(_ id: String) throws -> InstalledApp {
    guard let app = try installedApps().first(where: { $0.id == id || $0.namespace == id }) else {
      throw HostError("not_found", "Unknown application")
    }
    return app
  }
  public func sourceDirectory(_ id: String) throws -> URL {
    root.appendingPathComponent("apps/\(try app(id).id)/src")
  }
  public func activeDirectory(_ id: String) throws -> URL {
    let item = try app(id)
    guard item.version != "draft" else {
      throw HostError("unavailable", "Application has no validated version")
    }
    return root.appendingPathComponent("apps/\(item.id)/versions/\(item.version)")
  }
  public func preparePackage(_ id: String, context: RequestContext) throws -> PreparedPackage {
    try preparePackage(id, participants: [try app(id).id], context: context)
  }
  func preparePackage(_ id: String, participants: Set<String>, context: RequestContext) throws
    -> PreparedPackage
  {
    try require(context, capability: "app.commit", scope: id)
    let item = try app(id)
    let source = try sourceDirectory(item.id)
    let manifest = try Value.parse(
      String(contentsOf: SafePath.resolve("manifest.json", under: source), encoding: .utf8))
    guard manifest["schema"]?.string == "agentos.app/1", manifest["id"]?.string == item.id,
      let version = manifest["version"]?.string, Version(version) != nil,
      ["web", "macos-native", "wasm-component"].contains(manifest["runtime"]?["kind"]?.string ?? "")
    else { throw HostError("invalid_package", "Invalid manifest or unsupported runtime") }
    let definition = try AppInterface(
      Value.parse(
        String(
          contentsOf: SafePath.resolve("interface/interface.json", under: source), encoding: .utf8))
    )
    guard definition.namespace == item.namespace else {
      throw HostError("conflict", "Assigned namespace is immutable")
    }
    let runtimePaths =
      manifest["runtime"]?["kind"] == "macos-native"
      ? ["Sources"]
      : [
        manifest["runtime"]?["core"]?.string ?? "core.js",
        manifest["runtime"]?["ui"]?.string ?? "ui/index.html",
      ]
    for path in runtimePaths + ["tests/contract.json", "SPEC.md", "SKILL.md"] {
      _ = try SafePath.resolve(path, under: source)
    }
    if manifest["runtime"]?["kind"] == "wasm-component" {
      let path = try manifest["runtime"]!.requiredString("module")
      let module = try SafePath.resolve(path, under: source)
      guard try module.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= 10_000_000
      else { throw HostError("too_large", "WASM module exceeds 10 MB") }
      let bytes = try Data(contentsOf: module)
      guard bytes.prefix(8) == Data([0, 97, 115, 109, 1, 0, 0, 0]) else {
        throw HostError(
          "invalid_package",
          "Expected a WebAssembly core module v1; Component Model and WASI are not supported")
      }
    }
    if let backend = manifest["runtime"]?["backend"] {
      guard ["python", "node", "oci"].contains(backend["language"]?.string ?? ""),
        let files = backend["files"]?.array, !files.isEmpty, files.count <= 100,
        files.allSatisfy({ $0.string != nil }), Set(files).count == files.count,
        files.contains(.string(try backend.requiredString("entry"))),
        manifest["permissions"]?["services"]?.array?.contains("backend.call") == true
      else {
        throw HostError(
          "invalid_package", "Backend needs language, entry, files and backend.call permission")
      }
      for path in files { _ = try SafePath.resolve(path.string!, under: source) }
      if backend["language"] == "oci", files.count != 1 {
        throw HostError("invalid_package", "OCI backends accept one OCI image-layout tar archive")
      }
    }
    var interfaceChanges: [String] = []
    if item.version != "draft" {
      guard Version(version)! > Version(item.version)! else {
        throw HostError("conflict", "Version must increase")
      }
      interfaceChanges = definition.breakingChanges(from: try AppInterface(item.interface))
      if !interfaceChanges.isEmpty {
        guard participants.count > 1 else {
          throw HostError(
            "conflict", "Breaking interface changes require a joint dependency update",
            details: .array(interfaceChanges.map(Value.string)))
        }
        try requireNoCallDependents(item.namespace, excludingApps: participants)
      }
    }
    for collection in definition.data.keys {
      guard
        try db.query("SELECT collection FROM schemas WHERE collection=?", [.string(collection)])
          .first != nil
      else { throw HostError("invalid_schema", "Unknown collection \(collection)") }
    }
    _ = try definition.capabilities(manifest: manifest)
    var migration: PreparedDataChange?
    if let value = manifest["update"]?["dataSchema"], value != .null {
      let path = try value.requiredString("plan")
      let plan = try Value.parse(
        String(contentsOf: SafePath.resolve(path, under: source), encoding: .utf8))
      guard definition.data[plan["collection"]?.string ?? ""] == "rw" else {
        throw HostError(
          "invalid_package", "Migration requires declared read/write collection access")
      }
      migration = try prepareMigration(plan, excludingApps: participants, context: context)
    }
    let directory = root.appendingPathComponent("system/staging/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      try Self.copyTree(source, to: directory)
      return PreparedPackage(
        appID: item.id, version: version, baseVersion: item.version, directory: directory,
        manifest: manifest,
        interface: definition, digest: try Self.treeDigest(directory), migration: migration,
        interfaceChanges: interfaceChanges)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
  // Called only with host-owned contract-test evidence; never exposed directly to generated applications.
  public func activate(
    _ prepared: PreparedPackage, testsPassed: Bool, approvedCapabilities: Bool,
    context: RequestContext
  ) throws {
    try activatePackages(
      [prepared], testsPassed: testsPassed, approvedCapabilities: approvedCapabilities,
      context: context)
  }

  func validateActivation(
    _ prepared: PreparedPackage, participants: Set<String>, testsPassed: Bool,
    approvedCapabilities: Bool, context: RequestContext
  ) throws {
    try require(context, capability: "app.commit", scope: prepared.appID)
    guard testsPassed else {
      throw HostError("contract_failed", "Candidate failed its contract tests")
    }
    guard try Self.treeDigest(prepared.directory) == prepared.digest else {
      throw HostError("conflict", "Candidate changed after verification")
    }
    guard try app(prepared.appID).version == prepared.baseVersion else {
      throw HostError("conflict", "Active application version changed during verification")
    }
    let source = try sourceDirectory(prepared.appID)
    guard try Self.treeDigest(source) == prepared.digest else {
      throw HostError("conflict", "Source changed during verification; run tests again")
    }
    if !prepared.interfaceChanges.isEmpty {
      guard participants.count > 1 else {
        throw HostError("conflict", "Breaking candidate requires its joint update")
      }
      try requireNoCallDependents(prepared.interface.namespace, excludingApps: participants)
      guard approvedCapabilities else {
        throw HostError(
          "needs_confirmation", "Joint update changes tool contracts",
          details: .array(prepared.interfaceChanges.map(Value.string)))
      }
    }
    if let migration = prepared.migration {
      try require(context, capability: "schemas.migrate", scope: migration.collection)
      try requireNoDataDependents(migration.collection, excludingApps: participants)
      guard
        Self.digest(try collectionSnapshot(migration.collection).encoded()) == migration.baseDigest
      else {
        throw HostError("conflict", "Data changed while the candidate was tested; retry the commit")
      }
      guard approvedCapabilities else {
        throw HostError(
          "needs_confirmation", "This update migrates shared data", details: migration.summary)
      }
    }
    let permissions = prepared.manifest["permissions"] ?? [:]
    let hasExits = ["network", "services", "files"].contains {
      !(permissions[$0]?.array ?? []).isEmpty
    }
    let privateCollections = try db.query("SELECT collection FROM schemas WHERE private=1")
      .compactMap { $0["collection"]?.string }
    let labels = try self.labels(for: context)
    guard
      approvedCapabilities
        || (!hasExits && !labels.isUntrusted
          && !prepared.interface.data.keys.contains(where: privateCollections.contains))
    else { throw HostError("needs_confirmation", "New capabilities require host approval") }
  }

  func installPackage(_ prepared: PreparedPackage, context: RequestContext) throws {
    let source = try sourceDirectory(prepared.appID)
    let labels = try self.labels(for: context)
    try Self.git(["add", "--all"], directory: source)
    try Self.git(
      [
        "-c", "user.name=AgentOS", "-c", "user.email=local@agentos.invalid", "commit", "--quiet",
        "--allow-empty", "-m", "app: \(prepared.version)",
      ], directory: source)
    try db.transaction {
      try labelPackage(prepared.appID, with: labels)
      try db.execute(
        "UPDATE packages SET version=?,manifest=?,interface=? WHERE id=?",
        [
          .string(prepared.version), .string(try prepared.manifest.text()),
          .string(try prepared.interface.raw.text()), .string(prepared.appID),
        ])
      try db.execute(
        "INSERT INTO app_versions VALUES (?,?,?,?)",
        [
          .string(prepared.appID), .string(prepared.version), .string(prepared.digest),
          .string(Self.now()),
        ])
      let holder = Principal.core(prepared.appID).id
      // Existing grants are retained only when still requested. Revoked grants are never resurrected.
      let requested = try prepared.interface.capabilities(manifest: prepared.manifest).map {
        ($0.capability, $0.scope)
      }
      for row in try db.query(
        "SELECT * FROM grants WHERE holder=? AND revoked=0", [.string(holder)])
      {
        if !requested.contains(where: {
          $0.0 == row["capability"]?.string && $0.1 == row["scope"]?.string
        }) {
          try db.execute("UPDATE grants SET revoked=1 WHERE id=?", [row["id"]!])
        }
      }
      for (capability, scope) in requested {
        if try db.query(
          "SELECT id FROM grants WHERE holder=? AND capability=? AND scope=?",
          [.string(holder), .string(capability), .string(scope)]
        ).isEmpty {
          try db.execute(
            "INSERT INTO grants(id,holder,capability,scope) VALUES (?,?,?,?)",
            [.string(UUID().uuidString), .string(holder), .string(capability), .string(scope)])
        }
      }
      let event = DomainEvent(
        id: UUID().uuidString.lowercased(),
        type: (try appVersionCount(prepared.appID)) == 1 ? "app.installed" : "app.updated",
        source: "service:packages", subject: prepared.appID, time: Self.now(),
        labels: try packageLabels(prepared.appID), depth: context.depth, runID: context.runID,
        data: ["app": .string(prepared.appID), "version": .string(prepared.version)])
      try appendEvent(event)
      try audit(
        "app.activated", context: context,
        detail: ["id": .string(prepared.appID), "version": .string(prepared.version)])
    }
  }
  private func appVersionCount(_ id: String) throws -> Int {
    try db.query("SELECT COUNT(*) AS n FROM app_versions WHERE app_id=?", [.string(id)]).first?[
      "n"]?.int ?? 0
  }
  public func versions(_ id: String) throws -> [String] {
    return try db.query(
      "SELECT version FROM app_versions WHERE app_id=?", [.string(try app(id).id)]
    ).compactMap { $0["version"]?.string }.sorted { Version($0)! > Version($1)! }
  }
  public func rollback(_ id: String, version: String, context: RequestContext) throws {
    try require(context, capability: "app.rollback", scope: id)
    let item = try app(id)
    guard try versions(item.id).contains(version) else {
      throw HostError("not_found", "Unknown version")
    }
    let directory = root.appendingPathComponent("apps/\(item.id)/versions/\(version)")
    guard
      try db.query(
        "SELECT digest FROM app_versions WHERE app_id=? AND version=?",
        [.string(item.id), .string(version)]
      ).first?["digest"]?.string == Self.treeDigest(directory)
    else { throw HostError("invalid_package", "Version contents were modified") }
    let manifest = try Value.parse(
      String(contentsOf: directory.appendingPathComponent("manifest.json"), encoding: .utf8))
    let interface = try AppInterface(
      Value.parse(
        String(
          contentsOf: directory.appendingPathComponent("interface/interface.json"), encoding: .utf8)
      ))
    let source = try sourceDirectory(item.id)
    for name in try FileManager.default.contentsOfDirectory(atPath: source.path)
    where name != ".git" {
      try FileManager.default.removeItem(at: source.appendingPathComponent(name))
    }
    try Self.copyTree(directory, to: source)
    try Self.git(["add", "--all"], directory: source)
    try Self.git(
      [
        "-c", "user.name=AgentOS", "-c", "user.email=local@agentos.invalid", "commit", "--quiet",
        "--allow-empty", "-m", "app: rollback to \(version)",
      ], directory: source)
    try db.transaction {
      try db.execute(
        "UPDATE packages SET version=?,manifest=?,interface=? WHERE id=?",
        [
          .string(version), .string(try manifest.text()), .string(try interface.raw.text()),
          .string(item.id),
        ])
      let requested = try interface.capabilities(manifest: manifest).map {
        ($0.capability, $0.scope)
      }
      for grant in try db.query(
        "SELECT * FROM grants WHERE holder=? AND revoked=0", [.string(Principal.core(item.id).id)])
      where !requested.contains(where: {
        $0.0 == grant["capability"]?.string && $0.1 == grant["scope"]?.string
      }) {
        try db.execute("UPDATE grants SET revoked=1 WHERE id=?", [grant["id"]!])
      }
      try audit(
        "app.rollback", context: context,
        detail: ["id": .string(item.id), "from": .string(item.version), "to": .string(version)])
    }
  }
  public func searchTools(_ query: String, limit: Int = 20) throws -> Value {
    var found: [Value] = []
    for item in try installedApps() where item.version != "draft" {
      for tool in try AppInterface(item.interface).tools {
        let name = item.namespace + "." + tool.name
        if query.isEmpty
          || (name + " " + tool.title + " " + tool.description + " " + item.title)
            .localizedCaseInsensitiveContains(query)
        {
          found.append([
            "name": .string(name), "title": .string(tool.title),
            "description": .string(tool.description), "appID": .string(item.id),
          ])
        }
      }
    }
    return .array(Array(found.prefix(min(max(1, limit), 100))))
  }
  static func copyTree(_ source: URL, to destination: URL) throws {
    let source = source.resolvingSymlinksInPath().standardizedFileURL
    let fm = FileManager.default
    guard let items = fm.enumerator(atPath: source.path) else {
      throw HostError("invalid_package", "Cannot enumerate package")
    }
    var total = 0
    var count = 0
    for case let relative as String in items {
      let path = source.appendingPathComponent(relative)
      if path.lastPathComponent == ".git" {
        items.skipDescendants()
        continue
      }
      let values = try path.resourceValues(forKeys: [
        .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey,
      ])
      guard values.isSymbolicLink != true else {
        throw HostError("invalid_package", "Packages cannot contain symlinks")
      }
      count += 1
      total += values.fileSize ?? 0
      guard count <= 10000, total <= 200_000_000 else {
        throw HostError("invalid_package", "Package exceeds size limits")
      }
      let target = try SafePath.resolve(relative, under: destination, mustExist: false)
      if values.isDirectory == true {
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
      } else {
        try fm.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: path, to: target)
      }
    }
  }
  public static func treeDigest(_ directory: URL) throws -> String {
    let directory = directory.resolvingSymlinksInPath().standardizedFileURL
    guard let items = FileManager.default.enumerator(atPath: directory.path) else {
      throw HostError("invalid_package", "Cannot enumerate package")
    }
    var values: [String] = []
    for case let relative as String in items {
      let path = directory.appendingPathComponent(relative)
      if path.lastPathComponent == ".git" {
        items.skipDescendants()
        continue
      }
      guard try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
        throw HostError("invalid_package", "Packages cannot contain symlinks")
      }
      if try path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        values.append(relative + ":" + digest(try Data(contentsOf: path)))
      }
    }
    return digest(Data(values.sorted().joined(separator: "\n").utf8))
  }
  static func git(_ args: [String], directory: URL) throws {
    let p = Process()
    let output = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + args
    p.currentDirectoryURL = directory
    p.environment = [
      "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_TERMINAL_PROMPT": "0",
    ]
    p.standardOutput = output
    p.standardError = output
    try p.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
      throw HostError("build_failed", String(decoding: data, as: UTF8.self))
    }
  }
}
