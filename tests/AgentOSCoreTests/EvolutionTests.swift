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

private func expenseApp(_ kernel: Kernel, namespace: String) async throws -> InstalledApp {
  let app = try await kernel.createApp(title: namespace, namespace: namespace, context: user)
  let src = try await kernel.sourceDirectory(app.id)
  var interface = app.interface.object!
  interface["data"] = [["collection": "expenses", "access": "rw"]]
  try save(.object(interface), src.appendingPathComponent("interface/interface.json"))
  let candidate = try await kernel.preparePackage(app.id, context: user)
  try await kernel.activate(candidate, testsPassed: true, approvedCapabilities: true, context: user)
  return try await kernel.app(app.id)
}
private func stageExpenseUpdate(_ kernel: Kernel, app: InstalledApp, migration: Value? = nil)
  async throws
{
  let src = try await kernel.sourceDirectory(app.id)
  var manifest = app.manifest.object!
  manifest["version"] = "1.0.0+2"
  if let migration {
    manifest["update"] = ["dataSchema": ["plan": "migration.json"]]
    try save(migration, src.appendingPathComponent("migration.json"))
  }
  try save(.object(manifest), src.appendingPathComponent("manifest.json"))
}

@Test func jointMigrationRequiresAllConsumersAndCommitsOneSchemaAndBackup() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  try await k.registerSchema(
    collection: "expenses", type: "expense", definition: oldExpense, context: user)
  _ = try await k.put("expenses", id: "one", fields: ["title": "Tea", "amount": 8], context: user)
  let a = try await expenseApp(k, namespace: "ledger")
  let b = try await expenseApp(k, namespace: "report")
  try await stageExpenseUpdate(k, app: a, migration: expenseMigration)
  try await stageExpenseUpdate(k, app: b, migration: expenseMigration)
  await expectCode("conflict") { _ = try await k.preparePackage(a.id, context: user) }
  let group = try await k.preparePackages([a.id, b.id], context: user)
  await expectCode("contract_failed") {
    try await k.activatePackages(
      group, testsPassed: false, approvedCapabilities: true, context: user)
  }
  await expectCode("needs_confirmation") {
    try await k.activatePackages(
      group, testsPassed: true, approvedCapabilities: false, context: user)
  }
  #expect(try await k.app(a.id).version == "1.0.0+1")
  #expect(try await k.get("expenses", id: "one", context: user).fields["amount"] == 8)
  try await k.activatePackages(group, testsPassed: true, approvedCapabilities: true, context: user)
  #expect(try await k.app(a.id).version == "1.0.0+2")
  #expect(try await k.app(b.id).version == "1.0.0+2")
  #expect(try await k.get("expenses", id: "one", context: user).fields["total"] == 8)
  #expect(try await k.schemas().array?.first { $0["collection"] == "expenses" }?["version"] == 2)
  #expect(try await k.dataBackups().array?.count == 1)
  #expect(try await k.verifyAudit())
  try await k.shutdown()
}

@Test func jointMigrationRejectsConflictingPlansStaleDataAndNewConsumers() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  try await k.registerSchema(
    collection: "expenses", type: "expense", definition: oldExpense, context: user)
  let a = try await expenseApp(k, namespace: "ledger")
  let b = try await expenseApp(k, namespace: "report")
  try await stageExpenseUpdate(k, app: a, migration: expenseMigration)
  var different = expenseMigration.object!
  different["steps"] = [
    ["op": "rename", "from": "amount", "to": "total"],
    ["op": "default", "field": "currency", "value": "USD"],
  ]
  try await stageExpenseUpdate(k, app: b, migration: .object(different))
  await expectCode("conflict") { _ = try await k.preparePackages([a.id, b.id], context: user) }
  try await stageExpenseUpdate(k, app: b, migration: expenseMigration)
  let stale = try await k.preparePackages([a.id, b.id], context: user)
  _ = try await k.put("expenses", fields: ["title": "New", "amount": 1], context: user)
  await expectCode("conflict") {
    try await k.activatePackages(
      stale, testsPassed: true, approvedCapabilities: true, context: user)
  }
  let pending = try await k.preparePackages([a.id, b.id], context: user)
  _ = try await expenseApp(k, namespace: "newconsumer")
  await expectCode("conflict") {
    try await k.activatePackages(
      pending, testsPassed: true, approvedCapabilities: true, context: user)
  }
  #expect(try await k.app(a.id).version == "1.0.0+1")
  #expect(try await k.dataBackups().array?.isEmpty == true)
  try await k.shutdown()
}

extension Kernel {
  fileprivate func failActivation(of id: String) throws {
    // Fail late, after migration and at least one package update, inside the outer transaction.
    try db.execute(
      "CREATE TRIGGER fail_joint BEFORE INSERT ON app_versions WHEN NEW.app_id='\(id)' AND NEW.version='1.0.0+2' BEGIN SELECT RAISE(ABORT,'injected activation failure'); END"
    )
  }
}
@Test func jointActivationRollsBackDataEventsGrantsAndAllVersionsOnLateFailure() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  try await k.registerSchema(
    collection: "expenses", type: "expense", definition: oldExpense, context: user)
  _ = try await k.put("expenses", id: "one", fields: ["title": "Tea", "amount": 2], context: user)
  let a = try await expenseApp(k, namespace: "ledger")
  let b = try await expenseApp(k, namespace: "report")
  try await stageExpenseUpdate(k, app: a, migration: expenseMigration)
  try await stageExpenseUpdate(k, app: b)
  let group = try await k.preparePackages([a.id, b.id], context: user)
  let events = try await k.events()
  try await k.failActivation(of: group.last!.appID)
  await expectCode("storage") {
    try await k.activatePackages(
      group, testsPassed: true, approvedCapabilities: true, context: user)
  }
  #expect(try await k.app(a.id).version == "1.0.0+1")
  #expect(try await k.app(b.id).version == "1.0.0+1")
  #expect(try await k.get("expenses", id: "one", context: user).fields["amount"] == 2)
  #expect(try await k.history("expenses", id: "one", context: user).array?.count == 1)
  #expect(try await k.events() == events)
  for package in group {
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appendingPathComponent("apps/\(package.appID)/versions/\(package.version)")
          .path))
  }
  #expect(try await k.verifyAudit())
  try await k.shutdown()
}

@Test func jointInterfaceChangesRequireAllCallersAndRecheckNewCallers() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let a = try await k.createApp(title: "Producer", namespace: "producer", context: user)
  let source = try await k.sourceDirectory(a.id)
  try save(definition(a.namespace), source.appendingPathComponent("interface/interface.json"))
  let first = try await k.preparePackage(a.id, context: user)
  try await k.activate(first, testsPassed: true, approvedCapabilities: true, context: user)
  func caller(_ namespace: String) async throws -> InstalledApp {
    let app = try await k.createApp(title: namespace, namespace: namespace, context: user)
    let src = try await k.sourceDirectory(app.id)
    var value = app.interface.object!
    value["calls"] = ["producer.list"]
    try save(.object(value), src.appendingPathComponent("interface/interface.json"))
    let prepared = try await k.preparePackage(app.id, context: user)
    try await k.activate(prepared, testsPassed: true, approvedCapabilities: true, context: user)
    return try await k.app(app.id)
  }
  let b = try await caller("consumer")
  try await stageExpenseUpdate(k, app: a)
  try await stageExpenseUpdate(k, app: b)
  try save(
    definition(a.namespace, required: true),
    source.appendingPathComponent("interface/interface.json"))
  let spare = try await k.createApp(title: "Spare", namespace: "spare", context: user)
  await expectCode("conflict") { _ = try await k.preparePackages([a.id, spare.id], context: user) }
  let group = try await k.preparePackages([a.id, b.id], context: user)
  await expectCode("needs_confirmation") {
    try await k.activatePackages(
      group, testsPassed: true, approvedCapabilities: false, context: user)
  }
  let late = try await caller("lateconsumer")
  await expectCode("conflict") {
    try await k.activatePackages(
      group, testsPassed: true, approvedCapabilities: true, context: user)
  }
  try await stageExpenseUpdate(k, app: late)
  let complete = try await k.preparePackages([a.id, b.id, late.id], context: user)
  try await k.activatePackages(
    complete, testsPassed: true, approvedCapabilities: true, context: user)
  #expect(try await k.app(a.id).version == "1.0.0+2")
  #expect(try await k.app(b.id).version == "1.0.0+2")
  #expect(try await k.app(late.id).version == "1.0.0+2")
  try await k.shutdown()
}
