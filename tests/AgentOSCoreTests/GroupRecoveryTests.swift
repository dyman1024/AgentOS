import Foundation
import Testing

@testable import AgentOSCore

private func writer(_ k: Kernel) async throws -> RequestContext {
  let id = UUID().uuidString.lowercased()
  _ = try await k.grant(holder: .core(id), capability: "data.write", scope: "notes")
  return RequestContext(.core(id))
}
@Test func appGroupRecoveryPreservesIndependentFieldsAndPrivateLabels() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let app = try await writer(k)
  let privateRun = try await k.startRun(session: "private-source")
  let privateContext = RequestContext(.run(privateRun), runID: privateRun)
  try await k.propagate(Labels(taint: ["private-fixture"], isPrivate: true), to: privateContext)
  _ = try await k.put(
    "notes", id: "one", fields: ["title": "Original", "body": "Keep"], context: privateContext)
  _ = try await k.put(
    "notes", id: "one", fields: ["title": "A", "body": "Keep"], expectedRevision: 1, context: app)
  _ = try await k.put(
    "notes", id: "one", fields: ["title": "B", "body": "Keep"], expectedRevision: 2, context: app)
  _ = try await k.put(
    "notes", id: "one", fields: ["title": "B", "body": "Independent"], expectedRevision: 3,
    context: user)
  let selection: Value = ["kind": "app", "id": .string(app.principal.appID!)]
  let preview = try await k.prepareGroupRecovery(selection, context: user)
  #expect(preview.summary["effects"] == 2)
  #expect(preview.summary["canApply"] == true)
  await expectCode("needs_confirmation") {
    _ = try await k.applyGroupRecovery(preview, approved: false, context: user)
  }
  _ = try await k.applyGroupRecovery(preview, approved: true, context: user)
  let restored = try await k.get("notes", id: "one", context: user)
  #expect(restored.fields == ["title": "Original", "body": "Independent"])
  #expect(restored.rev == 5)
  #expect(restored.labels.isPrivate)
  #expect(try await k.dataBackups().array?.count == 1)
  await expectCode("conflict") {
    _ = try await k.applyGroupRecovery(preview, approved: true, context: user)
  }
  #expect(try await k.verifyAudit())
  try await k.shutdown()
}
@Test func runGroupRecoveryIncludesCalledCoresAndLeavesOtherRunsAlone() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let app = try await writer(k)
  let run = try await k.startRun(session: "run-group")
  let other = try await k.startRun(session: "other")
  let core = RequestContext(app.principal, runID: run)
  _ = try await k.put("notes", id: "one", fields: ["title": "From core"], context: core)
  _ = try await k.put(
    "tasks", id: "two", fields: ["title": "From run", "done": false],
    context: RequestContext(.run(run), runID: run))
  _ = try await k.put(
    "notes", id: "keep", fields: ["title": "Other"],
    context: RequestContext(.run(other), runID: other))
  let preview = try await k.prepareGroupRecovery(
    ["kind": "run", "id": .string(run)], context: user)
  #expect(preview.summary["effects"] == 2)
  _ = try await k.applyGroupRecovery(preview, approved: true, context: user)
  #expect(try await k.query("notes", context: user).map(\.id) == ["keep"])
  #expect(try await k.query("tasks", context: user).isEmpty)
  try await k.shutdown()
}
@Test func groupRecoveryRejectsABAAndStalePreviewWithoutPartialWrites() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let app = try await writer(k)
  _ = try await k.put("notes", id: "one", fields: ["title": "Original"], context: user)
  _ = try await k.put(
    "notes", id: "one", fields: ["title": "App"], expectedRevision: 1, context: app)
  _ = try await k.put("notes", id: "two", fields: ["title": "New"], context: app)
  let selection: Value = ["kind": "app", "id": .string(app.principal.appID!)]
  let stale = try await k.prepareGroupRecovery(selection, context: user)
  _ = try await k.put(
    "notes", id: "one", fields: ["title": "Other"], expectedRevision: 2, context: user)
  _ = try await k.put(
    "notes", id: "one", fields: ["title": "App"], expectedRevision: 3, context: user)
  await expectCode("conflict") {
    _ = try await k.applyGroupRecovery(stale, approved: true, context: user)
  }
  let conflict = try await k.prepareGroupRecovery(selection, context: user)
  #expect(conflict.summary["canApply"] == false)
  #expect(conflict.summary["conflicts"]?.array?.first?["fields"] == ["title"])
  await expectCode("conflict") {
    _ = try await k.applyGroupRecovery(conflict, approved: true, context: user)
  }
  #expect(try await k.get("notes", id: "two", context: user).rev == 1)
  #expect(try await k.dataBackups().array?.isEmpty == true)
  await expectCode("denied") { _ = try await k.prepareGroupRecovery(selection, context: app) }
  try await k.shutdown()
}

@Test func groupedRecoveryCanUndoAndRedoWithoutReplayingSourceEffects() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let app = try await writer(k)
  _ = try await k.put("notes", id: "one", fields: ["title": "Original"], context: user)
  let write = try await k.put(
    "notes", id: "one", fields: ["title": "App"], expectedRevision: 1, context: app)
  let preview = try await k.prepareGroupRecovery(
    ["kind": "app", "id": .string(app.principal.appID!)], context: user)
  _ = try await k.applyGroupRecovery(preview, approved: true, context: user)
  let recovery = try await k.activities().first!
  let undo = try await k.undo(recovery.id, context: user)
  #expect(undo.record.fields["title"] == "App")
  #expect(try await k.activities().first { $0.id == write.effectID }?.state == "applied")
  let redo = try await k.undo(undo.effectID, context: user)
  #expect(redo.record.fields["title"] == "Original")
  #expect(try await k.activities().first { $0.id == write.effectID }?.state == "undone")
  #expect(try await k.verifyAudit())
  try await k.shutdown()
}

extension Kernel {
  fileprivate func backdateEffect(_ id: String) throws {
    try db.execute("UPDATE effects SET at='2000-01-01T00:00:00Z' WHERE id=?", [.string(id)])
  }
  fileprivate func recordNonDataEffect(_ context: RequestContext) throws {
    try db.execute(
      "INSERT INTO effects(id,run_id,principal,class,action,target,state,at) VALUES ('external-fixture',?,?,'irreversible','mail.send','fixture','done',?)",
      [
        context.runID.map(Value.string) ?? .null, .string(context.principal.id),
        .string(Self.now()),
      ])
  }
}
@Test func groupedTimepointRestoresDeletesAndExplicitlyExcludesExternalEffects() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let app = try await writer(k)
  let run = try await k.startRun(session: "app-run", initiator: app.principal)
  let delegated = RequestContext(.run(run), runID: run)
  let old = try await k.put(
    "notes", id: "one", fields: ["title": "Keep older app write"], context: delegated)
  try await k.backdateEffect(old.effectID)
  _ = try await k.delete("notes", id: "one", expectedRevision: 1, context: delegated)
  try await k.recordNonDataEffect(delegated)
  let preview = try await k.prepareGroupRecovery(
    ["kind": "app", "id": .string(app.principal.appID!), "after": "2020-01-01T00:00:00Z"],
    context: user)
  #expect(preview.summary["effects"] == 1)
  #expect(preview.summary["excluded"]?.array?.first?["action"] == "mail.send")
  _ = try await k.applyGroupRecovery(preview, approved: true, context: user)
  #expect(
    try await k.get("notes", id: "one", context: user).fields["title"] == "Keep older app write")
  #expect(try await k.activities().first { $0.id == "external-fixture" }?.state == "done")
  try await k.shutdown()
}
