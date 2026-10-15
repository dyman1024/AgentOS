import Foundation
import Testing

@testable import AgentOSCore

private let oldExpense: Value = [
  "type": "object", "properties": ["title": ["type": "string"], "amount": ["type": "number"]],
  "required": ["title", "amount"],
]
private let newExpense: Value = [
  "type": "object",
  "properties": [
    "title": ["type": "string"], "total": ["type": "number"], "currency": ["type": "string"],
  ], "required": ["title", "total", "currency"], "additionalProperties": false,
]
private let expenseMigration: Value = [
  "schema": "agentos.migration/1", "collection": "expenses", "fromVersion": 1, "toVersion": 2,
  "definition": newExpense,
  "steps": [
    ["op": "rename", "from": "amount", "to": "total"],
    ["op": "default", "field": "currency", "value": "CNY"],
  ],
]

@Test func migrationPreviewRejectsStaleDataAndRestoreKeepsLabelsAndHistory() async throws {
  let (kernel, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  try await kernel.registerSchema(
    collection: "expenses", type: "expense", definition: oldExpense, isPrivate: true, context: user)
  let first = try await kernel.put(
    "expenses", id: "one", fields: ["title": "Coffee", "amount": 20], context: user)
  let prepared = try await kernel.prepareMigration(expenseMigration, context: user)
  _ = try await kernel.put(
    "expenses", id: "one", fields: ["title": "Coffee", "amount": 25],
    expectedRevision: first.record.rev, context: user)
  await expectCode("conflict") {
    _ = try await kernel.applyDataChange(prepared, approved: true, context: user)
  }
  let fresh = try await kernel.prepareMigration(expenseMigration, context: user)
  await expectCode("needs_confirmation") {
    _ = try await kernel.applyDataChange(fresh, approved: false, context: user)
  }
  let applied = try await kernel.applyDataChange(fresh, approved: true, context: user)
  let migrated = try await kernel.get("expenses", id: "one", context: user)
  #expect(
    migrated.fields["total"] == 25 && migrated.fields["amount"] == nil && migrated.labels.isPrivate)
  #expect(try await kernel.schemaReferences()["user:schema/expense@1"] == oldExpense)
  #expect(try await kernel.schemaReferences()["user:schema/expense@2"] == newExpense)
  let restore = try await kernel.prepareCollectionRestore(
    "expenses", backupID: applied.requiredString("backup"), context: user)
  _ = try await kernel.applyDataChange(restore, approved: true, context: user)
  let restored = try await kernel.get("expenses", id: "one", context: user)
  #expect(restored.fields["amount"] == 25 && restored.fields["total"] == nil)
  #expect(restored.rev > migrated.rev && restored.labels.isPrivate)
  #expect(try await kernel.schemaReferences()["user:schema/expense@3"] == oldExpense)
  #expect(try await kernel.verifyAudit())
  try await kernel.shutdown()
}

@Test func migrationAndActivationAreAtomicAndSharedDependentsBlockMigration() async throws {
  let (kernel, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  try await kernel.registerSchema(
    collection: "expenses", type: "expense", definition: oldExpense, context: user)
  _ = try await kernel.put("expenses", fields: ["title": "Tea", "amount": 10], context: user)
  let app = try await kernel.createApp(title: "Ledger", namespace: "ledger", context: user)
  let src = try await kernel.sourceDirectory(app.id)
  var definition = app.interface.object!
  definition["data"] = [["collection": "expenses", "access": "rw"]]
  try save(.object(definition), src.appendingPathComponent("interface/interface.json"))
  var manifest = app.manifest.object!
  manifest["update"] = ["dataSchema": ["plan": "migration.json"]]
  try save(.object(manifest), src.appendingPathComponent("manifest.json"))
  try save(expenseMigration, src.appendingPathComponent("migration.json"))
  let candidate = try await kernel.preparePackage(app.id, context: user)
  await expectCode("contract_failed") {
    try await kernel.activate(
      candidate, testsPassed: false, approvedCapabilities: true, context: user)
  }
  #expect(try await kernel.query("expenses", context: user)[0].fields["amount"] == 10)
  await expectCode("needs_confirmation") {
    try await kernel.activate(
      candidate, testsPassed: true, approvedCapabilities: false, context: user)
  }
  try await kernel.activate(candidate, testsPassed: true, approvedCapabilities: true, context: user)
  #expect(try await kernel.app(app.id).version == "1.0.0+1")
  #expect(try await kernel.query("expenses", context: user)[0].fields["total"] == 10)
  var another = expenseMigration.object!
  another["fromVersion"] = 2
  another["toVersion"] = 3
  another["steps"] = []
  await expectCode("conflict") {
    _ = try await kernel.prepareMigration(.object(another), context: user)
  }
  #expect(try await kernel.dataBackups().array?.count == 1)
  try await kernel.shutdown()
}

@Test func invalidMigrationAndTimepointRestoreDoNotPartiallyWrite() async throws {
  let (kernel, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  try await kernel.registerSchema(
    collection: "expenses", type: "expense", definition: oldExpense, context: user)
  _ = try await kernel.put(
    "expenses", id: "one", fields: ["title": "A", "amount": 1], context: user)
  _ = try await kernel.put(
    "expenses", id: "two", fields: ["title": "B", "amount": 2, "total": 9], context: user)
  await expectCode("conflict") {
    _ = try await kernel.prepareMigration(expenseMigration, context: user)
  }
  #expect(
    try await kernel.query("expenses", context: user).allSatisfy { $0.fields["amount"] != nil })
  let restore = try await kernel.prepareTimepointRestore(
    "expenses", at: "2000-01-01T00:00:00Z", context: user)
  _ = try await kernel.applyDataChange(restore, approved: true, context: user)
  #expect(try await kernel.query("expenses", context: user).isEmpty)
  #expect(try await kernel.history("expenses", id: "one", context: user).array?.count == 2)
  #expect(try await kernel.verifyAudit())
  try await kernel.shutdown()
}
