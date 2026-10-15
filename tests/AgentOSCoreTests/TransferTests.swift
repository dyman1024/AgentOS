import CryptoKit
import Foundation
import Testing

@testable import AgentOSCore

@Test func dataImportPreservesPrivacyAndRollsBackEveryRecordOnConflict() async throws {
  let (source, sourceRoot) = try fixture()
  let (target, targetRoot) = try fixture()
  defer {
    try? FileManager.default.removeItem(at: sourceRoot)
    try? FileManager.default.removeItem(at: targetRoot)
  }
  let user = RequestContext(.user)
  _ = try await source.put("notes", id: "a", fields: ["title": "import first"], context: user)
  _ = try await source.put("memory", id: "z", fields: ["content": "private"], context: user)
  let archive = try await source.exportData()
  _ = try await target.importData(archive)
  let memory = try await target.get("memory", id: "z", context: user)
  #expect(memory.labels.isPrivate && memory.labels.isUntrusted)
  #expect(try await target.query("notes", context: user).count == 1)
  await expectCode("denied") {
    _ = try await target.importData(archive, issuer: .core("untrusted"))
  }
  await expectCode("conflict") { _ = try await target.importData(archive) }
  var edited = archive.object!
  var values = archive["records"]!.array!
  let new: Value = [
    "collection": "notes", "id": "new-record", "rev": 1, "fields": ["title": "rolled back"],
    "labels": ["taint": [], "isPrivate": false], "deleted": false,
  ]
  values.insert(new, at: 0)
  edited["records"] = .array(values)
  let conflicting = Value.object(edited)
  await expectCode("conflict") { _ = try await target.importData(conflicting) }
  await expectCode("not_found") {
    _ = try await target.get("notes", id: "new-record", context: user)
  }
  let backup = try await target.backupData()
  #expect(
    FileManager.default.fileExists(
      atPath: targetRoot.appendingPathComponent("system/backups/" + backup + ".json").path))
  #expect(try await target.verifyAudit())
  try await source.shutdown()
  try await target.shutdown()
}

@Test func packageTransferCarriesCustomSchemasAndAllocatesFreshIdentity() async throws {
  let (source, sourceRoot) = try fixture()
  let (target, targetRoot) = try fixture()
  defer {
    try? FileManager.default.removeItem(at: sourceRoot)
    try? FileManager.default.removeItem(at: targetRoot)
  }
  let user = RequestContext(.user)
  let definition: Value = [
    "type": "object", "properties": ["amount": ["type": "number"]], "required": ["amount"],
  ]
  try await source.registerSchema(
    collection: "expenses", type: "expense", definition: definition, context: user)
  let app = try await source.createApp(title: "Ledger", namespace: "ledger", context: user)
  let directory = try await source.sourceDirectory(app.id)
  var interface = app.interface.object!
  interface["data"] = [["collection": "expenses", "access": "rw"]]
  try Value.object(interface).encoded().write(
    to: directory.appendingPathComponent("interface/interface.json"))
  let prepared = try await source.preparePackage(app.id, context: user)
  try await source.activate(prepared, testsPassed: true, approvedCapabilities: true, context: user)
  let bytes = try await source.exportPackage(
    app.id, signingKey: Curve25519.Signing.PrivateKey().rawRepresentation, context: user)
  let fingerprint = try PackageArchive.verify(bytes).fingerprint
  let imported = try await target.importPackage(
    bytes, acceptedFingerprint: fingerprint, context: user)
  #expect(imported.id != app.id && imported.version == "draft")
  #expect(
    try await target.schemas().array?.contains(where: { $0["collection"] == "expenses" }) == true)
  let candidate = try await target.preparePackage(imported.id, context: user)
  #expect(candidate.interface.data["expenses"] == "rw")
  #expect(try await target.grants().array?.isEmpty == true)
  await expectCode("denied") {
    _ = try await target.importPackage(bytes, acceptedFingerprint: "changed", context: user)
  }
  try await source.shutdown()
  try await target.shutdown()
}

@Test func fileCompensationCannotCrossApplicationOwnership() async throws {
  let (kernel, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("shared")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let id = try await kernel.addFolder(folder)["id"]!.string!
  for name in ["one", "two"] {
    _ = try await kernel.grant(holder: .core(name), capability: "files", scope: id)
  }
  let result = try await kernel.writeFile(
    ["folder": .string(id), "path": "note.txt", "text": "owned"],
    context: RequestContext(.core("one")))
  await expectCode("denied") {
    _ = try await kernel.undoFile(
      result["effectID"]!.string!, context: RequestContext(.core("two")))
  }
  _ = try await kernel.undoFile(result["effectID"]!.string!, context: RequestContext(.user))
  #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("note.txt").path))
  try await kernel.shutdown()
}

@Test func knownURLsAreExactAndBoundToTheirRun() async throws {
  let (kernel, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let first = try await kernel.startRun(session: "first")
  let second = try await kernel.startRun(session: "second")
  let context = RequestContext(.run(first), runID: first)
  try await kernel.rememberUserLinks(
    "请阅读 https://example.com/article?id=1 和 https://127.0.0.1/no", context: context)
  #expect(try await kernel.isKnownURL("https://example.com/article?id=1", context: context))
  #expect(
    try await !kernel.isKnownURL("https://example.com/article?id=1&secret=value", context: context))
  #expect(
    try await !kernel.isKnownURL(
      "https://example.com/article?id=1", context: RequestContext(.run(second), runID: second)))
  try await kernel.finishRun(first)
  await expectCode("denied") {
    try await kernel.rememberURLs(["https://example.com/late"], context: context)
  }
  try await kernel.shutdown()
}

@Test func importedPackageMetadataAndPrivateActivityPropagateLabels() async throws {
  let (kernel, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let id = try await kernel.startRun(session: "source")
  let context = RequestContext(.run(id), runID: id)
  try await kernel.propagate(Labels(taint: ["web:source"], isPrivate: true), to: context)
  let app = try await kernel.createApp(
    title: "Private generation", namespace: "privategen", context: context)
  #expect(try await kernel.packageLabels(app.id).isPrivate)
  let reader = try await kernel.startRun(session: "read-source")
  let reading = RequestContext(.run(reader), runID: reader)
  _ = try await kernel.route("apps.describe", args: ["app": .string(app.id)], context: reading)
  #expect(try await kernel.labels(for: reading).isPrivate)
  #expect(try await kernel.labels(for: reading).taint.contains("web:source"))
  let effect = try await kernel.put(
    "memory", fields: ["content": "Private preference"], context: user)
  let inspect = try await kernel.startRun(session: "activity")
  let inspection = RequestContext(.run(inspect), runID: inspect)
  _ = try await kernel.activityDetails(effect.effectID, context: inspection)
  #expect(try await kernel.labels(for: inspection).isPrivate)
  try await kernel.shutdown()
}
