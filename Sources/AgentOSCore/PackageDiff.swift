import Foundation

extension Kernel {
  public func packageDiff(_ id: String, from: String, to: String, context: RequestContext) throws
    -> Value
  {
    let item = try app(id)
    try require(context, capability: "app.read", scope: item.id)
    try propagate(packageLabels(item.id), to: context)
    func directory(_ version: String) throws -> URL {
      if version == "draft" { return try sourceDirectory(item.id) }
      guard try versions(item.id).contains(version) else {
        throw HostError("not_found", "Unknown package version")
      }
      let path = root.appendingPathComponent("apps/\(item.id)/versions/\(version)")
      guard
        try db.query(
          "SELECT digest FROM app_versions WHERE app_id=? AND version=?",
          [.string(item.id), .string(version)]
        ).first?["digest"]?.string == Self.treeDigest(path)
      else {
        throw HostError("invalid_package", "Version contents changed")
      }
      return path
    }
    func files(_ directory: URL) throws -> [String: URL] {
      guard let iterator = FileManager.default.enumerator(atPath: directory.path) else {
        return [:]
      }
      var result: [String: URL] = [:]
      var bytes = 0
      for case let name as String in iterator {
        if name == ".git" {
          iterator.skipDescendants()
          continue
        }
        let path = try SafePath.resolve(name, under: directory)
        let info = try path.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard info.isSymbolicLink != true else {
          throw HostError("invalid_package", "Symlink in source tree")
        }
        if info.isRegularFile == true {
          result[name] = path
          bytes += info.fileSize ?? 0
        }
        guard result.count <= 10000, bytes <= 200_000_000 else {
          throw HostError("too_large", "Source tree exceeds package limits")
        }
      }
      return result
    }
    let old = try files(directory(from))
    let new = try files(directory(to))
    var differences: [Value] = []
    var total = 0
    for path in Set(old.keys).union(new.keys).sorted() {
      let before = try old[path].map { try Data(contentsOf: $0) }
      let after = try new[path].map { try Data(contentsOf: $0) }
      if before == after { continue }
      total += 1
      if differences.count >= 30 { continue }
      func content(_ bytes: Data?) -> Value {
        guard let bytes else { return .null }
        return [
          "sha256": .string(Self.digest(bytes)), "bytes": .number(Double(bytes.count)),
          "text": String(data: bytes.prefix(16000), encoding: .utf8).map(Value.string) ?? .null,
          "truncated": .bool(bytes.count > 16000),
        ]
      }
      differences.append([
        "path": .string(path),
        "change": before == nil ? "added" : after == nil ? "removed" : "modified",
        "before": content(before), "after": content(after),
      ])
    }
    return [
      "app": .string(item.id), "from": .string(from), "to": .string(to),
      "changedFiles": .number(Double(total)),
      "truncated": .bool(total > differences.count), "files": .array(differences),
    ]
  }
}
