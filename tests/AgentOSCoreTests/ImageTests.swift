import CryptoKit
import Foundation
import Testing

@testable import AgentOSCore

@Test func workbenchImagesRequireTrustedSignatureAndExactContent() throws {
  let key = Curve25519.Signing.PrivateKey()
  let bytes = Data("fixture disk".utf8)
  let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  let artifact: Value = [
    "url": "https://images.example.com/disk", "bytes": .number(Double(bytes.count)),
    "sha256": .string(hash),
  ]
  let payload = try Value.object([
    "version": "1.0.0", "architecture": "arm64", "os": "linux", "kernel": artifact,
    "disk": artifact,
  ]).encoded()
  let envelope: Value = [
    "schema": "agentos.workbench/1", "payload": .string(payload.base64EncodedString()),
    "signature": .string(try key.signature(for: payload).base64EncodedString()),
  ]
  let manifest = try envelope.encoded()
  let image = try WorkbenchImage(
    manifest: manifest, trustedPublicKey: key.publicKey.rawRepresentation.base64EncodedString())
  #expect(image.version == "1.0.0")
  #expect(throws: HostError.self) {
    _ = try WorkbenchImage(
      manifest: manifest,
      trustedPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        .base64EncodedString())
  }
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  try bytes.write(to: file)
  try image.disk.verify(file)
  try Data("tampered disk".utf8).write(to: file)
  #expect(throws: HostError.self) { try image.disk.verify(file) }
  try Data(repeating: 0, count: bytes.count).write(to: file)
  #expect(throws: HostError.self) { try image.disk.verify(file) }
}
