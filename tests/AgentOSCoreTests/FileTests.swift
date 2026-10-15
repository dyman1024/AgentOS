import Foundation
import Testing

@testable import AgentOSCore

@Test func folderGrantsPathsUndoAndRevocation() async throws {
  let (k, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("authorized")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let authorization = try await k.addFolder(folder)
  let id = authorization["id"]!.string!
  let c = RequestContext(.core("files"))
  await expectCode("denied") {
    _ = try await k.writeFile(
      ["folder": .string(id), "path": "note.txt", "text": "first"], context: c)
  }
  _ = try await k.grant(holder: .core("files"), capability: "files", scope: id)
  let first = try await k.writeFile(
    ["folder": .string(id), "path": "note.txt", "text": "first"], context: c)
  #expect(
    try await k.readFile(["folder": .string(id), "path": "note.txt"], context: c)["text"] == "first"
  )
  await expectCode("conflict") {
    _ = try await k.writeFile(
      ["folder": .string(id), "path": "note.txt", "text": "without revision"], context: c)
  }
  let second = try await k.writeFile(
    ["folder": .string(id), "path": "note.txt", "text": "second", "expectedHash": first["hash"]!],
    context: c)
  await expectCode("conflict") { _ = try await k.undoFile(first["effectID"]!.string!, context: c) }
  _ = try await k.undoFile(second["effectID"]!.string!, context: c)
  _ = try await k.undoFile(first["effectID"]!.string!, context: c)
  #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("note.txt").path))
  try FileManager.default.createSymbolicLink(
    at: folder.appendingPathComponent("escape"), withDestinationURL: root)
  await expectCode("denied") {
    _ = try await k.readFile(
      ["folder": .string(id), "path": "escape/system/kernel.sqlite"], context: c)
  }
  await expectCode("denied") {
    _ = try await k.writeFile(
      ["folder": .string(id), "path": "../outside.txt", "text": "no"], context: c)
  }
  try await k.revokeFolder(id)
  await expectCode("denied") {
    _ = try await k.readFile(["folder": .string(id), "path": "note.txt"], context: c)
  }
}

@Test func trashAndDirectoryUndoPreserveSubsequentFiles() async throws {
  let (kernel, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("authorized")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let id = try await kernel.addFolder(folder)["id"]!.string!
  let context = RequestContext(.user)
  let directory = try await kernel.makeDirectory(
    ["folder": .string(id), "path": "project"], context: context)
  let file = try await kernel.writeFile(
    ["folder": .string(id), "path": "project/readme.txt", "text": "recoverable"], context: context)
  await expectCode("conflict") {
    _ = try await kernel.undoFile(directory["effectID"]!.string!, context: context)
  }
  let trashed = try await kernel.trashFile(
    ["folder": .string(id), "path": "project/readme.txt", "expectedHash": file["hash"]!],
    context: context)
  #expect(
    !FileManager.default.fileExists(
      atPath: folder.appendingPathComponent("project/readme.txt").path))
  _ = try await kernel.undoFile(trashed["effectID"]!.string!, context: context)
  #expect(
    try await kernel.readFile(
      ["folder": .string(id), "path": "project/readme.txt"], context: context)["text"]
      == "recoverable")
  _ = try await kernel.undoFile(file["effectID"]!.string!, context: context)
  _ = try await kernel.undoFile(directory["effectID"]!.string!, context: context)
  #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("project").path))
  try await kernel.shutdown()
}

@Test func mediaIndexDeduplicatesAndKeepsProgressAndPrivateLabels() async throws {
  let (kernel, root) = try fixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("media")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let id = try await kernel.addFolder(folder)["id"]!.string!
  let context = RequestContext(.user)
  let item = try await kernel.indexMedia(
    folder: id, path: "song.wav", title: "Song", kind: "music", bytes: 100, context: context)
  try await kernel.saveMediaProgress(folder: id, path: "song.wav", seconds: 32, context: context)
  let rescanned = try await kernel.indexMedia(
    folder: id, path: "song.wav", title: "Song", kind: "music", bytes: 100, context: context)
  #expect(
    rescanned.id == item.id && rescanned.fields["progress"] == 32 && rescanned.labels.isPrivate)
  #expect(try await kernel.query("media", context: context).count == 1)
  try await kernel.revokeFolder(id)
  await expectCode("denied") {
    try await kernel.saveMediaProgress(folder: id, path: "song.wav", seconds: 40, context: context)
  }
  try await kernel.shutdown()
}
