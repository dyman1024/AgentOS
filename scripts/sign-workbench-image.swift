#!/usr/bin/env swift  // Signs a distribution manifest; never uploads artifacts or prints the private key.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 7 else {
  fputs(
    "Usage: sign-workbench-image.swift <32-byte-private-key-file> <version> <https-base-url> <kernel> <disk.ext4> <output.json>\n",
    stderr)
  exit(2)
}
let key = try Curve25519.Signing.PrivateKey(
  rawRepresentation: Data(contentsOf: URL(fileURLWithPath: args[1])))
guard let base = URL(string: args[3]), base.scheme == "https", base.host != nil, base.user == nil,
  base.password == nil
else { fatalError("Use an HTTPS distribution base URL") }
func artifact(_ path: String, name: String) throws -> [String: Any] {
  let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
  defer { try? handle.close() }
  var digest = SHA256()
  var bytes = 0
  while let chunk = try handle.read(upToCount: 1_000_000), !chunk.isEmpty {
    digest.update(data: chunk)
    bytes += chunk.count
  }
  return [
    "url": base.appendingPathComponent(name).absoluteString, "bytes": bytes,
    "sha256": digest.finalize().map { String(format: "%02x", $0) }.joined(),
  ]
}
let payload = try JSONSerialization.data(
  withJSONObject: [
    "version": args[2], "architecture": "arm64", "os": "linux",
    "kernel": artifact(args[4], name: "kernel"), "disk": artifact(args[5], name: "disk.ext4"),
  ], options: [.sortedKeys])
let envelope: [String: Any] = [
  "schema": "agentos.workbench/1", "payload": payload.base64EncodedString(),
  "signature": try key.signature(for: payload).base64EncodedString(),
]
try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .prettyPrinted]).write(
  to: URL(fileURLWithPath: args[6]), options: .atomic)
print("Public key: " + key.publicKey.rawRepresentation.base64EncodedString())
print(
  "Manifest saved. Distribute kernel, disk.ext4 and the manifest over HTTPS; communicate the public key separately."
)
