import Foundation
import Testing

@testable import AgentOSCore

@Test func publicationRejectsPathsAndRollsBackDefiniteFailure() async throws {
  for path in ["../a.md", "/a.md", ".github/workflows/action.md", "a/../x.md", "x.txt"] {
    #expect(throws: HostError.self) {
      try Publication(repository: "test/repo", path: path, content: "body", title: "Title")
    }
  }
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let doc = try await k.put(
    "documents", fields: ["title": "Draft", "body": "Text", "status": "draft"], context: user)
  let publisher = Publisher(kernel: k)
  let args: Value = [
    "document": .string(doc.record.id), "repository": "test/repo", "path": "article.md",
  ]
  await expectCode("service_error") {
    _ = try await publisher.publish(
      args, context: user, confirm: nil,
      upload: { _ in throw HostError("service_error", "Rejected") })
  }
  #expect(
    try await k.get("documents", id: doc.record.id, context: user).fields["status"] == "draft")
  #expect(try await k.activities().contains { $0.action == "publish" && $0.state == "failed" })
}
@Test func uncertainPublicationDoesNotRetryOrPretendDeploymentSucceeded() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let doc = try await k.put(
    "documents", fields: ["title": "Draft", "body": "Text", "status": "draft"], context: user)
  let publisher = Publisher(kernel: k)
  let args: Value = [
    "document": .string(doc.record.id), "repository": "test/repo", "path": "article.md",
  ]
  await expectCode("network_error") {
    _ = try await publisher.publish(
      args, context: user, confirm: nil,
      upload: { _ in throw HostError("network_error", "Lost connection") })
  }
  #expect(
    try await k.get("documents", id: doc.record.id, context: user).fields["publicationState"]
      == "unknown")
  #expect(try await k.pendingSinks().array?.first?["state"] == "unknown")
}
