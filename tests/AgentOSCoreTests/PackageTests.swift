import Foundation
import Testing

@testable import AgentOSCore

func save(_ value: Value, _ file: URL) throws {
  try value.encoded().write(to: file, options: .atomic)
}
func definition(_ namespace: String, required: Bool = false) -> Value {
  [
    "schema": "agentos.interface/1", "id": .string(namespace), "version": "1.0.0",
    "tools": [
      [
        "name": "list", "description": "List notes",
        "input": [
          "type": "object", "properties": ["query": ["type": "string"]],
          "required": required ? ["query"] : [],
        ], "output": ["type": "array", "items": ["type": "object"]], "examples": [["input": [:]]],
      ]
    ], "data": [["collection": "notes", "access": "rw"]],
  ]
}
@Test func versionsRejectMalformedStrings() {
  for value in ["1.x.2.3", "1.2.3+-1", "01.2.3", "1.2.3+", "1.2", "1.2.3.4"] {
    #expect(Version(value) == nil)
  }
  #expect(Version("1.2.3+4")! > Version("1.2.3+3")!)
}
@Test func installFailureIsNotActivatedAndRollbackPreservesData() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let a = try await k.createApp(title: "Notes", namespace: "notes", context: user)
  let source = try await k.sourceDirectory(a.id)
  try save(definition(a.namespace), source.appendingPathComponent("interface/interface.json"))
  let p = try await k.preparePackage(a.id, context: user)
  await expectCode("contract_failed") {
    try await k.activate(p, testsPassed: false, approvedCapabilities: false, context: user)
  }
  #expect(try await k.versions(a.id).isEmpty)
  #expect(try await k.app(a.id).version == "draft")
  try await k.activate(p, testsPassed: true, approvedCapabilities: false, context: user)
  let core = RequestContext(.core(a.id))
  _ = try await k.put("notes", fields: ["title": "User data"], context: core)
  var m = a.manifest.object!
  m["version"] = "1.0.1+2"
  try save(.object(m), source.appendingPathComponent("manifest.json"))
  let next = try await k.preparePackage(a.id, context: user)
  try await k.activate(next, testsPassed: true, approvedCapabilities: false, context: user)
  try await k.rollback(a.id, version: "1.0.0+1", context: user)
  #expect(try await k.app(a.id).version == "1.0.0+1")
  #expect(try await k.query("notes", context: core).count == 1)
  #expect(try await k.verifyAudit())
}
@Test func packageTamperingAndBreakingChangesFail() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let a = try await k.createApp(title: "A", context: user)
  let source = try await k.sourceDirectory(a.id)
  try save(definition(a.namespace), source.appendingPathComponent("interface/interface.json"))
  let prepared = try await k.preparePackage(a.id, context: user)
  try Data("changed".utf8).write(to: source.appendingPathComponent("core.js"))
  await expectCode("conflict") {
    try await k.activate(prepared, testsPassed: true, approvedCapabilities: false, context: user)
  }
  let good = try await k.preparePackage(a.id, context: user)
  try await k.activate(good, testsPassed: true, approvedCapabilities: false, context: user)
  var manifest = a.manifest.object!
  manifest["version"] = "1.0.1+2"
  try save(.object(manifest), source.appendingPathComponent("manifest.json"))
  try save(
    definition(a.namespace, required: true),
    source.appendingPathComponent("interface/interface.json"))
  await expectCode("conflict") { _ = try await k.preparePackage(a.id, context: user) }
}
@Test func revokedCapabilitiesRemainRevokedOnUpgrade() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let a = try await k.createApp(title: "A", context: user)
  let source = try await k.sourceDirectory(a.id)
  try save(definition(a.namespace), source.appendingPathComponent("interface/interface.json"))
  let p = try await k.preparePackage(a.id, context: user)
  try await k.activate(p, testsPassed: true, approvedCapabilities: false, context: user)
  for grant in try await k.grants().array ?? [] { try await k.revoke(grant["id"]!.string!) }
  var m = a.manifest.object!
  m["version"] = "1.0.1+2"
  try save(.object(m), source.appendingPathComponent("manifest.json"))
  let p2 = try await k.preparePackage(a.id, context: user)
  try await k.activate(p2, testsPassed: true, approvedCapabilities: false, context: user)
  await expectCode("denied") {
    _ = try await k.query("notes", context: RequestContext(.core(a.id)))
  }
}
@Test func pathsAndPackageSymlinksCannotEscape() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let a = try await k.createApp(title: "A", context: user)
  let source = try await k.sourceDirectory(a.id)
  try FileManager.default.createSymbolicLink(
    at: source.appendingPathComponent("escape"),
    withDestinationURL: root.appendingPathComponent("system"))
  for path in ["../system/kernel.sqlite", "escape/kernel.sqlite", "/etc/passwd", ".git/config"] {
    await expectCode("denied") { _ = try SafePath.resolve(path, under: source) }
  }
  await expectCode("invalid_package") { _ = try await k.preparePackage(a.id, context: user) }
}
