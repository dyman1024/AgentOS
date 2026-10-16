import Foundation

extension Kernel {
  func requireNoCallDependents(_ namespace: String, excludingApps: Set<String>) throws {
    let missing = try installedApps().filter {
      guard $0.version != "draft", !excludingApps.contains($0.id) else { return false }
      return try AppInterface($0.interface).calls.contains { $0.hasPrefix(namespace + ".") }
    }
    guard missing.isEmpty else {
      throw HostError(
        "conflict", "Tool contract change requires all installed callers in the joint update",
        details: .array(missing.map { .string($0.namespace) }))
    }
  }

  /// Every installed consumer of a migrated collection must participate in the same tested update.
  public func preparePackages(_ ids: [String], context: RequestContext) throws -> [PreparedPackage]
  {
    guard !ids.isEmpty, ids.count <= 20 else {
      throw HostError("invalid_args", "An update contains 1–20 applications")
    }
    let participants = try Set(ids.map { try app($0).id })
    guard participants.count == ids.count else {
      throw HostError("invalid_args", "Duplicate update participant")
    }
    var packages: [PreparedPackage] = []
    do {
      for id in participants.sorted() {
        packages.append(try preparePackage(id, participants: participants, context: context))
      }
      _ = try jointMigrations(packages)
      return packages
    } catch {
      for package in packages { try? FileManager.default.removeItem(at: package.directory) }
      throw error
    }
  }

  func jointMigrations(_ packages: [PreparedPackage]) throws -> [PreparedDataChange] {
    var changes: [String: PreparedDataChange] = [:]
    for package in packages {
      guard let change = package.migration else { continue }
      if let previous = changes[change.collection] {
        guard previous.baseDigest == change.baseDigest, previous.definition == change.definition,
          previous.records == change.records, previous.summary == change.summary
        else {
          throw HostError(
            "conflict", "Participants declared different migrations for " + change.collection)
        }
      }
      changes[change.collection] = change
    }
    return changes.keys.sorted().map { changes[$0]! }
  }

  public func validatePackages(
    _ packages: [PreparedPackage], testsPassed: Bool,
    approvedCapabilities: Bool, context: RequestContext
  ) throws {
    let participants = Set(packages.map(\.appID))
    guard !packages.isEmpty, packages.count <= 20, participants.count == packages.count else {
      throw HostError("invalid_args", "Invalid update participants")
    }
    _ = try jointMigrations(packages)
    for package in packages {
      try validateActivation(
        package, participants: participants, testsPassed: testsPassed,
        approvedCapabilities: approvedCapabilities, context: context)
    }
  }

  /// Host-only activation evidence; production callers use RuntimeCoordinator.commitGroup.
  public func activatePackages(
    _ packages: [PreparedPackage], testsPassed: Bool,
    approvedCapabilities: Bool, context: RequestContext
  ) throws {
    try validatePackages(
      packages, testsPassed: testsPassed, approvedCapabilities: approvedCapabilities,
      context: context)
    let participants = Set(packages.map(\.appID))
    let changes = try jointMigrations(packages)
    let backup = changes.isEmpty ? nil : try backupData()
    var destinations: [URL] = []
    var committed = false
    defer {
      if !committed {
        for destination in destinations { try? FileManager.default.removeItem(at: destination) }
      }
    }
    // Files are staged before the authoritative transaction. No app can resolve these versions yet.
    for package in packages {
      let destination = root.appendingPathComponent(
        "apps/\(package.appID)/versions/\(package.version)")
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw HostError("conflict", "Immutable version already exists")
      }
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: package.directory, to: destination)
      destinations.append(destination)
      guard try Self.treeDigest(destination) == package.digest else {
        throw HostError("conflict", "Candidate changed while copying the validated version")
      }
    }
    try db.transaction {
      for change in changes { try installDataChange(change, context: context) }
      for package in packages { try installPackage(package, context: context) }
      if !changes.isEmpty {
        try audit(
          "data.migrated", context: context,
          detail: [
            "apps": .array(participants.sorted().map(Value.string)),
            "backup": backup.map(Value.string) ?? .null, "changes": .array(changes.map(\.summary)),
          ])
      }
    }
    committed = true
  }
}
