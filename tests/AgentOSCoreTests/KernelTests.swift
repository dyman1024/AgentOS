import Foundation
import NaturalLanguage
import Testing

@testable import AgentOSCore

func fixture() throws -> (Kernel, URL) {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "agentos-tests-" + UUID().uuidString)
  return (try Kernel(root: url), url)
}
let user = RequestContext(.user)
func expectCode(_ code: String, _ operation: () async throws -> Void) async {
  do {
    try await operation()
    Issue.record("Expected \(code)")
  } catch let e as HostError { #expect(e.code == code) } catch {
    Issue.record("Unexpected error: \(error)")
  }
}

@Test func revisionAndAtomicBatch() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let a = try await k.put("notes", fields: ["title": "周会", "body": "原始"], context: user)
  await expectCode("conflict") {
    _ = try await k.put(
      "notes", id: a.record.id, fields: ["title": "覆盖"], expectedRevision: 0, context: user)
  }
  await expectCode("conflict") {
    _ = try await k.batch(
      [
        Mutation("notes", fields: ["title": "不能留下"]),
        Mutation("notes", id: a.record.id, fields: ["title": "失败"], expectedRevision: 0),
      ], context: user)
  }
  #expect(try await k.query("notes", context: user).count == 1)
  #expect(try await k.activities().count == 1)
  #expect(try await k.events().array?.count == 1)
}
@Test func uiCannotWriteAndRevocationIsImmediate() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let g = try await k.grant(holder: .core("notes"), capability: "data.write", scope: "notes")
  await expectCode("denied") {
    _ = try await k.put("notes", fields: ["title": "No"], context: RequestContext(.ui("notes")))
  }
  _ = try await k.put("notes", fields: ["title": "Yes"], context: RequestContext(.core("notes")))
  try await k.revoke(g)
  await expectCode("denied") {
    _ = try await k.put("notes", fields: ["title": "No"], context: RequestContext(.core("notes")))
  }
}
@Test func delegatedRunCannotExpandAppPermissions() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try await k.grant(holder: .core("notes"), capability: "data.read", scope: "notes")
  let run = try await k.startRun(session: "app-session", initiator: .core("notes"))
  await expectCode("denied") {
    _ = try await k.put(
      "notes", fields: ["title": "Escalation"], context: RequestContext(.run(run), runID: run))
  }
}
@Test func cancelledAndOverBudgetRunsCannotWrite() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let run = try await k.startRun(session: "s", budget: 1)
  #expect(try await k.charge(run, usd: 1.01))
  await expectCode("denied") {
    _ = try await k.put(
      "notes", fields: ["title": "Late"], context: RequestContext(.run(run), runID: run))
  }
}
@Test func undoPreservesLaterIndependentFieldsAndRedoWorks() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let a = try await k.put("notes", fields: ["title": "A", "body": "original"], context: user)
  let b = try await k.put(
    "notes", id: a.record.id, fields: ["title": "B", "body": "original"], expectedRevision: 1,
    context: user)
  _ = try await k.put(
    "notes", id: a.record.id, fields: ["title": "B", "body": "later"], expectedRevision: 2,
    context: user)
  let undo = try await k.undo(b.effectID, context: user)
  #expect(undo.record.fields == ["title": "A", "body": "later"])
  let redo = try await k.undo(undo.effectID, context: user)
  #expect(redo.record.fields == ["title": "B", "body": "later"])
}
@Test func undoRejectsOverlappingAndABAWrites() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let a = try await k.put("notes", fields: ["title": "A"], context: user)
  let b = try await k.put(
    "notes", id: a.record.id, fields: ["title": "B"], expectedRevision: 1, context: user)
  _ = try await k.put(
    "notes", id: a.record.id, fields: ["title": "C"], expectedRevision: 2, context: user)
  _ = try await k.put(
    "notes", id: a.record.id, fields: ["title": "B"], expectedRevision: 3, context: user)
  await expectCode("conflict") { _ = try await k.undo(b.effectID, context: user) }
  await expectCode("conflict") { _ = try await k.undo(a.effectID, context: user) }
}
@Test func creationAndDeletionAreReversible() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let a = try await k.put("notes", fields: ["title": "A"], context: user)
  let u = try await k.undo(a.effectID, context: user)
  await expectCode("not_found") { _ = try await k.get("notes", id: a.record.id, context: user) }
  let redo = try await k.undo(u.effectID, context: user)
  #expect(!redo.record.deleted)
  let deleted = try await k.delete(
    "notes", id: a.record.id, expectedRevision: redo.record.rev, context: user)
  #expect(try await k.undo(deleted.effectID, context: user).record.fields["title"] == "A")
}
@Test func labelsPersistAcrossSessionAndData() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let run = try await k.startRun(session: "s")
  let ctx = RequestContext(.run(run), runID: run)
  try await k.propagate(Labels(taint: ["web:untrusted.example"], isPrivate: true), to: ctx)
  let record = try await k.put("notes", fields: ["title": "External"], context: ctx)
  #expect(record.record.labels.isPrivate)
  try await k.finishRun(run)
  let later = try await k.startRun(session: "s")
  #expect(try await k.labels(for: RequestContext(.run(later), runID: later)).isUntrusted)
  let clean = try await k.startRun(session: "fresh")
  #expect(try await !k.labels(for: RequestContext(.run(clean), runID: clean)).isUntrusted)
  _ = try await k.get(
    "notes", id: record.record.id, context: RequestContext(.run(clean), runID: clean))
  #expect(try await k.labels(for: RequestContext(.run(clean), runID: clean)).isUntrusted)
}
@Test func policyMatrix() {
  let external = Labels(taint: ["mail:sender"])
  #expect(ExitPolicy.evaluate(mode: .auto, effect: .write, labels: external) == .allow)
  #expect(ExitPolicy.evaluate(mode: .auto, effect: .irreversible, labels: Labels()) == .allow)
  if case .confirm = ExitPolicy.evaluate(mode: .auto, effect: .irreversible, labels: external) {
  } else {
    Issue.record("Expected confirmation")
  }
  if case .confirm = ExitPolicy.evaluate(
    mode: .auto, effect: .fetch, labels: external.union(Labels(isPrivate: true)))
  {
  } else {
    Issue.record("Expected egress confirmation")
  }
  #expect(ExitPolicy.evaluate(mode: .trust, effect: .irreversible, labels: external) == .allow)
}
@Test func deliveryLeaseReplayAndRevocation() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let core = RequestContext(.core("tasks"))
  let grant = try await k.grant(holder: .core("tasks"), capability: "subscribe", scope: "note.*")
  _ = try await k.grant(holder: .core("tasks"), capability: "data.read", scope: "notes")
  let id = try await k.subscribe(pattern: "note.*", context: core)
  _ = try await k.put("notes", fields: ["title": "Hello"], context: user)
  let now = Date()
  let first = try #require(await k.nextDelivery(id, context: core, now: now))
  #expect(try await k.nextDelivery(id, context: core, now: now) == nil)
  let replay = try #require(
    await k.nextDelivery(id, context: core, now: now.addingTimeInterval(31)))
  #expect(first.event.id == replay.event.id)
  await expectCode("conflict") {
    try await k.acknowledge(id, sequence: first.sequence + 1, context: core)
  }
  try await k.acknowledge(id, sequence: replay.sequence, context: core)
  #expect(try await k.nextDelivery(id, context: core, now: now.addingTimeInterval(62)) == nil)
  try await k.revoke(grant)
  await expectCode("denied") { _ = try await k.nextDelivery(id, context: core) }
}
@Test func restartAndAuditTamperDetection() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let a = try await k.put("notes", fields: ["title": "Persist"], context: user)
  #expect(try await k.verifyAudit())
  let reopened = try Kernel(root: root)
  #expect(
    try await reopened.get("notes", id: a.record.id, context: user).fields["title"] == "Persist")
  let db = try SQLiteStore(path: root.appendingPathComponent("system/kernel.sqlite").path)
  try db.execute("UPDATE audit SET payload='{}' WHERE seq=1")
  #expect(try await !reopened.verifyAudit())
}
@Test func unicodeSearchAndSchemaFailure() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try await k.put("notes", fields: ["title": "周会纪要", "body": "讨论季度规划"], context: user)
  #expect(try await k.query("notes", text: "周会", context: user).count == 1)
  #expect(try await k.query("notes", text: "季度规划", context: user).count == 1)
  await expectCode("invalid_args") {
    _ = try await k.put("notes", fields: ["body": "No title"], context: user)
  }
  await expectCode("invalid_args") {
    _ = try await k.put("notes", fields: ["title": "Spoof", "_rev": 1], context: user)
  }
}

@Test func budgetReservationsPreventConcurrentOverspendAndRecoverConservatively() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let id = try await k.startRun(session: "budget", budget: 1)
  let c = RequestContext(.run(id), runID: id)
  let reservation = try await k.reserveBudget(0.7, context: c)
  await expectCode("budget_exceeded") { _ = try await k.reserveBudget(0.4, context: c) }
  try await k.settleBudget(reservation, actual: 0.2)
  #expect(abs(try await k.remainingBudget(c) - 0.8) < 0.000001)
  _ = try await k.reserveBudget(0.3, context: c)
  let restarted = try Kernel(root: root)
  let run = try await restarted.runs().array!.first!
  #expect(run["status"] == "interrupted")
  #expect(abs(run["spent"]!.number! - 0.5) < 0.000001)
}

@Test func schemaDefinitionsRejectSilentConstraintBypassesAndTypeShadowing() async throws {
  for schema: Value in [
    ["type": 42], ["enum": "anything"], ["minimum": "1"], ["minimum": 2, "maximum": 1],
    ["maxLength": -1], ["additionalProperties": [:]],
  ] {
    #expect(throws: HostError.self) { try Schema.lint(schema) }
  }
  let (kernel, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  await expectCode("conflict") {
    try await kernel.registerSchema(
      collection: "shadow", type: "note", definition: [:], context: user)
  }
  let run = try await kernel.startRun(session: "terminated-budget", budget: 1)
  _ = try await kernel.reserveBudget(0.7, context: RequestContext(.run(run), runID: run))
  try await kernel.finishRun(run, status: "failed")
  #expect(abs(try await kernel.runCost(run) - 0.7) < 0.000001)
  try await kernel.shutdown()
}
@Test(
  .enabled(
    if: NLEmbedding.sentenceEmbedding(for: .simplifiedChinese) != nil,
    "Requires Apple's installed Chinese sentence model; missing assets are not a passed integration check"
  ))
func privateSemanticSearchStaysLocalAndTracksRevisions() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let item = try await k.put(
    "notes", fields: ["title": "学习强化学习", "body": "奖励函数、策略优化和智能体训练。"], context: user)
  _ = try await k.put("notes", fields: ["title": "番茄炒鸡蛋", "body": "晚餐菜谱，做饭的方法。"], context: user)
  let result = try await k.semanticQuery("notes", text: "机器学习与智能体训练", context: user)
  #expect(result.array?.first?["_id"] == .string(item.record.id))
  _ = try await k.put(
    "notes", id: item.record.id, fields: ["title": "花园", "body": "浇水种花"], expectedRevision: 1,
    context: user)
  let next = try await k.semanticQuery("notes", text: "植物与种花", context: user)
  #expect(next.array?.first?["_rev"] == 2)
  #expect(try LocalEmbedding.embed("个人隐私资料")["local"] == true)
}

@Test func unavailableLocalEmbeddingNeverFallsBackToAnExternalModel() async {
  await expectCode("unavailable") {
    _ = try LocalEmbedding.embed("私人资料", language: "zz-unavailable")
  }
}

@Test func cancelledUsageCanReconcileOnceWithoutReopeningTheRun() async throws {
  let (kernel, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let id = try await kernel.startRun(session: "cancel-usage", budget: 2)
  let context = RequestContext(.run(id), runID: id)
  let reservation = try await kernel.reserveBudget(1, context: context)
  try await kernel.finishRun(id, status: "cancelled")
  #expect(try await kernel.runCost(id) == 1)
  try await kernel.settleBudget(reservation, actual: 0.3)
  try await kernel.settleBudget(reservation, actual: 0.3)
  #expect(try await abs(kernel.runCost(id) - 0.3) < 0.000001)
  await expectCode("denied") { try await kernel.validateContext(context) }
  await expectCode("conflict") { try await kernel.settleBudget(reservation, actual: 0) }
  #expect(try await kernel.verifyAudit())
  try await kernel.shutdown()
}
