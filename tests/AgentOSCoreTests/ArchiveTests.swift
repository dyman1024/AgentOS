import CryptoKit
import Foundation
import Testing

@testable import AgentOSCore

@Test func signedArchiveRejectsTamperingTraversalAndWrongSignature() throws {
  let key = Curve25519.Signing.PrivateKey()
  let files = ["core.js": Data("export const value = 1;".utf8), "ui/中文.html": Data("Hello".utf8)]
  let signed = try PackageArchive.sign(files: files, key: key)
  #expect(try PackageArchive.verify(signed).files == files)
  var entries = try PackageArchive.unzip(signed)
  entries["payload/core.js"] = Data("export const value = 2;".utf8)
  #expect(throws: HostError.self) { try PackageArchive.verify(PackageArchive.zip(entries)) }
  entries = try PackageArchive.unzip(signed)
  entries["signature.ed25519"] = Data(repeating: 0, count: 64)
  #expect(throws: HostError.self) { try PackageArchive.verify(PackageArchive.zip(entries)) }
  #expect(throws: HostError.self) { try PackageArchive.zip(["../escape": Data()]) }
  #expect(throws: HostError.self) { try PackageArchive.zip(["X": Data(), "x": Data()]) }
  #expect(throws: HostError.self) { try PackageArchive.unzip(signed.dropLast()) }
}

@Test func rangedFileReadRemainsConfinedAndRevocationIsChecked() async throws {
  let (kernel, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("shared")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  try Data("0123456789".utf8).write(to: folder.appendingPathComponent("video.mp4"))
  try FileManager.default.createSymbolicLink(
    at: folder.appendingPathComponent("escape"),
    withDestinationURL: root.appendingPathComponent("system/kernel.sqlite"))
  let grant = try await kernel.addFolder(folder)
  let id = grant["id"]!.string!
  let stream = try await kernel.openAuthorizedFile(
    ["folder": .string(id), "path": "video.mp4"], context: user)
  #expect(try stream.read(offset: 3, count: 4) == Data("3456".utf8))
  await expectCode("denied") {
    _ = try await kernel.openAuthorizedFile(
      ["folder": .string(id), "path": "escape"], context: user)
  }
  try await kernel.revokeFolder(id)
  await expectCode("denied") { try await kernel.checkFolder(id, context: user) }
  try await kernel.shutdown()
}
