import Darwin
import Foundation

extension Kernel {
  public func makeDirectory(_ args: Value, context: RequestContext) throws -> Value {
    let folder = try args.requiredString("folder")
    let path = try args.requiredString("path")
    let url = try folderURL(folder, context: context)
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let (fd, name) = try ConfinedFiles.parent(path, root: url)
    defer { close(fd) }
    var info = stat()
    guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
      throw HostError("conflict", "Directory target already exists")
    }
    let ticket = try prepareSink(
      action: "files.mkdir", args: args, effect: .write, capability: "files", scope: folder,
      context: context)
    _ = try claimSink(ticket.id, context: context)
    do {
      guard mkdirat(fd, name, 0o700) == 0, fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
        info.st_mode & S_IFMT == S_IFDIR
      else { throw HostError("io_error", "Could not create directory") }
      try db.execute(
        "INSERT INTO directory_history VALUES (?,?,?,?,?)",
        [
          .string(ticket.id), .string(folder), .string(path), .string(String(info.st_dev)),
          .string(String(info.st_ino)),
        ])
      try finishSink(ticket.id, state: "done", result: ["created": true])
    } catch {
      try? finishSink(
        ticket.id, state: "unknown", result: ["message": .string(error.localizedDescription)])
      throw error
    }
    return ["effectID": .string(ticket.id), "created": true]
  }
  func undoDirectory(_ id: String, context: RequestContext) throws -> Value {
    guard
      let row = try db.query(
        "SELECT d.*,s.context FROM directory_history d JOIN sink_operations s ON d.id=s.id WHERE d.id=? AND s.state='done'",
        [.string(id)]
      ).first
    else { throw HostError("conflict", "Directory operation is not reversible") }
    try requireEffectOwner(row["context"]!.string!, context: context)
    let folder = row["folder"]!.string!
    let path = row["path"]!.string!
    let url = try folderURL(folder, context: context)
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let (fd, name) = try ConfinedFiles.parent(path, root: url)
    defer { close(fd) }
    var info = stat()
    guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR,
      String(info.st_dev) == row["device"]?.string, String(info.st_ino) == row["inode"]?.string
    else { throw HostError("conflict", "Directory was moved or replaced") }
    let ticket = try prepareSink(
      action: "files.undoDirectory", args: ["effectID": .string(id)], effect: .write,
      capability: "files", scope: folder, context: context)
    _ = try claimSink(ticket.id, context: context)
    guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else {
      try? finishSink(
        ticket.id, state: "failed", result: ["reason": "Directory changed or is not empty"])
      throw HostError("conflict", "Directory changed or contains new files; nothing was removed")
    }
    try finishSink(ticket.id, state: "done", result: ["removed": true])
    try finishSink(id, state: "compensated", result: ["undo": .string(ticket.id)])
    return ["effectID": .string(ticket.id), "removed": true]
  }
}
