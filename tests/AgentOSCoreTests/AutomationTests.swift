import Foundation
import Testing

@testable import AgentOSCore

@Test func automationRequiresFixedNoninteractivePlanAndHonorsRevocation() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let app = try await k.createApp(title: "Notes", namespace: "notes", context: user)
  let source = try await k.sourceDirectory(app.id)
  try save(definition("notes"), source.appendingPathComponent("interface/interface.json"))
  let candidate = try await k.preparePackage(app.id, context: user)
  try await k.activate(candidate, testsPassed: true, approvedCapabilities: false, context: user)
  let plan: Value = [
    "name": "Review notes", "trigger": ["event": "note.created"],
    "steps": [["tool": "notes.list", "args": [:]]],
  ]
  let id = try await k.createAutomation(plan, context: user)
  #expect(try await k.nextAutomation(id) == nil)
  _ = try await k.put("notes", fields: ["title": "Trigger"], context: user)
  let job = try #require(await k.nextAutomation(id))
  #expect(try await k.nextAutomation(id) == nil)
  let context = RequestContext(.run(job.runID), runID: job.runID)
  try await k.authorize(context, capability: "call", scope: "notes.list")
  await expectCode("denied") {
    try await k.authorize(context, capability: "call", scope: "other.send")
  }
  try await k.finishAutomation(job)
  #expect(try await k.nextAutomation(id) == nil)
  #expect(try await k.verifyAudit())
  let caller = Principal.core("consumer")
  let call = try await k.grant(holder: caller, capability: "call", scope: "notes.list")
  _ = try await k.grant(holder: caller, capability: "automation.create", scope: "*")
  let scheduled = try await k.createAutomation(
    ["name": "Read", "trigger": ["everySeconds": 60], "steps": [["tool": "notes.list"]]],
    context: RequestContext(caller))
  try await k.revoke(call)
  await expectCode("denied") { _ = try await k.nextAutomation(scheduled) }
}
@Test func nestedTransactionRollsBackBothLevels() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let db = try SQLiteStore(path: dir.path)
  try db.execute("CREATE TABLE test(id INTEGER)")
  do {
    try db.transaction {
      try db.execute("INSERT INTO test VALUES (1)")
      try db.transaction { try db.execute("INSERT INTO test VALUES (2)") }
      throw HostError("test", "rollback")
    }
  } catch {}
  #expect(try db.query("SELECT * FROM test").isEmpty)
}

@Test func compatibleToolUpgradePausesAutomationUntilHostReapproval() async throws {
  let (kernel, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let app = try await kernel.createApp(title: "Reader", namespace: "reader", context: user)
  let source = try await kernel.sourceDirectory(app.id)
  try save(definition("reader"), source.appendingPathComponent("interface/interface.json"))
  let first = try await kernel.preparePackage(app.id, context: user)
  try await kernel.activate(first, testsPassed: true, approvedCapabilities: false, context: user)
  let id = try await kernel.createAutomation(
    [
      "name": "Read", "trigger": ["everySeconds": 60],
      "steps": [["tool": "reader.list", "args": [:]]],
    ], context: user)
  var interface = definition("reader").object!
  var tool = interface["tools"]!.array![0].object!
  tool["input"] = [
    "type": "object", "properties": ["query": ["type": "string"], "limit": ["type": "integer"]],
    "required": [],
  ]
  interface["tools"] = [.object(tool)]
  try save(.object(interface), source.appendingPathComponent("interface/interface.json"))
  var manifest = app.manifest.object!
  manifest["version"] = "1.1.0+2"
  try save(.object(manifest), source.appendingPathComponent("manifest.json"))
  let upgrade = try await kernel.preparePackage(app.id, context: user)
  try await kernel.activate(upgrade, testsPassed: true, approvedCapabilities: false, context: user)
  await expectCode("conflict") { _ = try await kernel.nextAutomation(id) }
  #expect(try await kernel.automations().array?.first?["enabled"] == false)
  await expectCode("needs_confirmation") {
    try await kernel.setAutomation(id, enabled: true, context: user)
  }
  try await kernel.setAutomation(id, enabled: true, approved: true, context: user)
  let job = try #require(await kernel.nextAutomation(id))
  try await kernel.finishAutomation(job)
  #expect(try await kernel.verifyAudit())
  try await kernel.shutdown()
}
