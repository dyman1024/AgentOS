import CryptoKit
import Foundation

extension Kernel {
  public func exportPackage(_ id: String, signingKey: Data, context: RequestContext) throws -> Data
  {
    try require(context, capability: "app.export", scope: id)
    let directory = try activeDirectory(id)
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKey)
    guard let entries = FileManager.default.enumerator(atPath: directory.path) else {
      throw HostError("io_error", "Cannot enumerate application")
    }
    var files: [String: Data] = [:]
    var total = 0
    for case let name as String in entries {
      let url = directory.appendingPathComponent(name)
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isSymbolicLink != true else {
        throw HostError("invalid_package", "Package contains a link")
      }
      if values.isRegularFile == true {
        total += values.fileSize ?? 0
        guard total <= 200_000_000, files.count < 10000 else {
          throw HostError("too_large", "Package exceeds limits")
        }
        files[name] = try Data(contentsOf: url)
      }
    }
    let collections = Set(try AppInterface(app(id).interface).data.keys)
    files["data-schemas.json"] = try Value.array(
      (schemas().array ?? []).filter { collections.contains($0["collection"]?.string ?? "") }
    ).encoded()
    return try PackageArchive.sign(files: files, key: key)
  }
  /// Verified imports become new drafts. Contract tests and fresh capabilities are still required.
  public func importPackage(_ bytes: Data, acceptedFingerprint: String, context: RequestContext)
    throws -> InstalledApp
  {
    try db.transaction {
      try importPackageContents(bytes, acceptedFingerprint: acceptedFingerprint, context: context)
    }
  }
  private func importPackageContents(
    _ bytes: Data, acceptedFingerprint: String, context: RequestContext
  ) throws -> InstalledApp {
    try require(context, capability: "app.create", scope: "*")
    let verified = try PackageArchive.verify(bytes)
    guard verified.fingerprint == acceptedFingerprint else {
      throw HostError("denied", "Publisher fingerprint changed")
    }
    guard let rawManifest = verified.files["manifest.json"],
      let rawInterface = verified.files["interface/interface.json"]
    else { throw HostError("invalid_package", "Package metadata is missing") }
    var manifest = try Value.parse(String(decoding: rawManifest, as: UTF8.self)).object ?? [:]
    var definition = try Value.parse(String(decoding: rawInterface, as: UTF8.self)).object ?? [:]
    let parsed = try AppInterface(.object(definition))
    guard manifest["schema"] == "agentos.app/1" else {
      throw HostError("invalid_package", "Invalid application manifest")
    }
    if let raw = verified.files["data-schemas.json"] {
      guard let schemas = try Value.parse(String(decoding: raw, as: UTF8.self)).array,
        schemas.count <= 1000
      else { throw HostError("invalid_package", "Invalid schema declarations") }
      for schema in schemas {
        try registerSchema(
          collection: schema.requiredString("collection"), type: schema.requiredString("type"),
          definition: Value.parse(schema.requiredString("definition")),
          isPrivate: schema["private"]?.int == 1, version: schema["version"]?.int ?? 1,
          context: context)
      }
    }
    let item = try createApp(
      title: manifest["title"]?.string ?? parsed.namespace, namespace: parsed.namespace,
      context: context)
    do {
      let directory = try sourceDirectory(item.id)
      for url in try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil) where url.lastPathComponent != ".git"
      { try FileManager.default.removeItem(at: url) }
      for (name, content) in verified.files {
        let target = try SafePath.resolve(name, under: directory, mustExist: false)
        try FileManager.default.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: target)
      }
      manifest["id"] = .string(item.id)
      manifest["version"] = "1.0.0+1"
      manifest["agent"] = nil
      manifest["update"] = nil
      manifest["provenance"] = ["importedSigner": .string(verified.fingerprint)]
      definition["id"] = .string(item.namespace)
      try Value.object(manifest).encoded().write(
        to: directory.appendingPathComponent("manifest.json"), options: .atomic)
      try Value.object(definition).encoded().write(
        to: directory.appendingPathComponent("interface/interface.json"), options: .atomic)
      try labelPackage(item.id, with: Labels(taint: ["package:" + verified.fingerprint]))
      try audit(
        "package.imported", context: context,
        detail: ["app": .string(item.id), "signer": .string(verified.fingerprint)])
      return item
    } catch {
      try? db.execute("DELETE FROM packages WHERE id=?", [.string(item.id)])
      try? FileManager.default.removeItem(at: root.appendingPathComponent("apps/" + item.id))
      throw error
    }
  }
}
