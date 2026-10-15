import Foundation
import Testing

@testable import AgentOSCore

@Test func sinkConfirmationBindsArgumentsAndCannotBeReplayed() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let run = try await k.startRun(session: "sink")
  let context = RequestContext(.run(run), runID: run)
  try await k.propagate(Labels(taint: ["web:source"]), to: context)
  let ticket = try await k.prepareSink(
    action: "mail.send", args: ["to": "recipient@example.test", "body": "draft"],
    effect: .irreversible, capability: "service", scope: "mail.send", context: context)
  #expect(ticket.state == "pending")
  await expectCode("needs_confirmation") { _ = try await k.claimSink(ticket.id, context: context) }
  await expectCode("denied") {
    try await k.approveSink(ticket.id, allow: true, issuer: .core("untrusted"))
  }
  try await k.approveSink(ticket.id, allow: true)
  #expect(try await k.claimSink(ticket.id, context: context) == ticket.args)
  await expectCode("conflict") { _ = try await k.claimSink(ticket.id, context: context) }
  try await k.finishSink(
    ticket.id, state: "unknown", result: ["reason": "Connection lost after sending"])
  await expectCode("conflict") { _ = try await k.claimSink(ticket.id, context: context) }
  #expect(try await k.activities().first?.state == "unknown")
}
@Test func newTaintAndRevocationInvalidatePreviouslyAllowedExit() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let run = try await k.startRun(session: "sink")
  let context = RequestContext(.run(run), runID: run)
  let ticket = try await k.prepareSink(
    action: "publish", args: ["repo": "demo"], effect: .irreversible, capability: "service",
    scope: "publish", context: context)
  #expect(ticket.state == "ready")
  try await k.propagate(Labels(taint: ["web:late"]), to: context)
  await expectCode("needs_confirmation") { _ = try await k.claimSink(ticket.id, context: context) }
  let app = RequestContext(.core("writer"))
  let grant = try await k.grant(holder: .core("writer"), capability: "service", scope: "publish")
  let next = try await k.prepareSink(
    action: "publish", args: [:], effect: .irreversible, capability: "service", scope: "publish",
    context: app)
  try await k.revoke(grant)
  await expectCode("denied") { _ = try await k.claimSink(next.id, context: app) }
}
@Test func restartMarksInFlightExternalEffectsUnknown() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let t = try await k.prepareSink(
    action: "net.fetch", args: ["url": "https://example.test"], effect: .irreversible,
    capability: "service", scope: "net.fetch", context: user)
  _ = try await k.claimSink(t.id, context: user)
  let restored = try Kernel(root: root)
  #expect(try await restored.pendingSinks().array?.first?["state"] == "unknown")
  await expectCode("conflict") { _ = try await restored.claimSink(t.id, context: user) }
}
@Test func userRulesAreExactAndCannotBeInstalledByApplications() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  await expectCode("denied") {
    _ = try await k.addRule(
      action: "mail.send", equals: ["to": "a@example.test"], issuer: .core("app"))
  }
  _ = try await k.addRule(action: "mail.send", equals: ["to": "a@example.test"])
  let run = try await k.startRun(session: "rules")
  let context = RequestContext(.run(run), runID: run)
  try await k.propagate(Labels(taint: ["mail:source"]), to: context)
  let allowed = try await k.prepareSink(
    action: "mail.send", args: ["to": "a@example.test"], effect: .irreversible,
    capability: "service", scope: "mail.send", context: context)
  let other = try await k.prepareSink(
    action: "mail.send", args: ["to": "b@example.test"], effect: .irreversible,
    capability: "service", scope: "mail.send", context: context)
  #expect(allowed.state == "ready" && other.state == "pending")
}
@Test func metadataAndPrivateCollectionsAreHostOwned() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let first = try await k.put(
    "contacts", fields: ["name": "Person", "emails": ["a@example.test"]], context: user)
  #expect(first.record.labels.isPrivate)
  #expect(first.record.createdBy == "user" && first.record.createdAt != nil)
  let run = try await k.startRun(session: "private")
  let context = RequestContext(.run(run), runID: run)
  _ = try await k.get("contacts", id: first.record.id, context: context)
  #expect(try await k.labels(for: context).isPrivate)
  let changed = try await k.put(
    "contacts", id: first.record.id, fields: ["name": "Updated"], expectedRevision: 1,
    context: context)
  #expect(changed.record.createdBy == "user" && changed.record.updatedBy == Principal.run(run).id)
}
