import CryptoKit
import Darwin
import Foundation

/// Relative openat traversal rejects symlinks at each component, including the final file.
enum ConfinedFiles {
  static func parent(_ path: String, root: URL) throws -> (Int32, String) {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !parts.isEmpty, parts.count <= 64,
      parts.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") && !$0.contains("\\")
          && $0.utf8.count <= 255
      })
    else { throw HostError("denied", "Invalid relative path") }
    var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw HostError("denied", "Folder is unavailable") }
    for part in parts.dropLast() {
      let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      close(fd)
      fd = next
      guard fd >= 0 else { throw HostError("denied", "Directory traversal refused") }
    }
    return (fd, parts.last!)
  }
  static func read(_ name: String, fd: Int32) throws -> Data? {
    let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    if file < 0 && errno == ENOENT { return nil }
    guard file >= 0 else { throw HostError("denied", "Cannot open file or symbolic link") }
    defer { close(file) }
    var info = stat()
    guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 2_000_000
    else { throw HostError("denied", "Only regular files up to 2 MB are supported") }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      let n = Darwin.read(file, &buffer, buffer.count)
      if n == 0 { break }
      guard n > 0, data.count + n <= 2_000_000 else {
        throw HostError("too_large", "File changed or read failed")
      }
      data.append(contentsOf: buffer.prefix(n))
    }
    return data
  }
  static func replace(_ name: String, fd: Int32, bytes: Data?) throws {
    guard let bytes else {
      guard unlinkat(fd, name, 0) == 0 else {
        throw HostError("io_error", "Could not remove created file")
      }
      _ = fsync(fd)
      return
    }
    let temp = ".agentos-" + UUID().uuidString
    let file = openat(fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard file >= 0 else { throw HostError("io_error", "Cannot prepare file") }
    defer {
      close(file)
      unlinkat(fd, temp, 0)
    }
    try bytes.withUnsafeBytes { buffer in
      var sent = 0
      while sent < buffer.count {
        let n = Darwin.write(file, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
        guard n > 0 else { throw HostError("io_error", "File write failed") }
        sent += n
      }
    }
    guard fsync(file) == 0, renameat(fd, temp, fd, name) == 0 else {
      throw HostError("io_error", "File replacement failed")
    }
    _ = fsync(fd)
  }
  static func hash(_ data: Data?) -> String {
    data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "absent"
  }
}
extension Kernel {
  public func addFolder(_ url: URL, issuer: Principal = .user) throws -> Value {
    guard issuer == .user, url.isFileURL else {
      throw HostError("denied", "Only the host folder picker can authorize a directory")
    }
    let resolved = url.resolvingSymlinksInPath()
    var info = stat()
    guard stat(resolved.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
      throw HostError("invalid_args", "Choose a folder")
    }
    let bookmark = try resolved.bookmarkData(
      options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    let id = UUID().uuidString.lowercased()
    try db.execute(
      "INSERT INTO folders VALUES (?,?,?,1)",
      [.string(id), .string(resolved.lastPathComponent), .string(bookmark.base64EncodedString())])
    try audit(
      "folder.authorized", context: RequestContext(.user),
      detail: ["id": .string(id), "title": .string(resolved.lastPathComponent)])
    return ["id": .string(id), "title": .string(resolved.lastPathComponent)]
  }
  public func folders(context: RequestContext) throws -> Value {
    try validateContext(context)
    let rows = try db.query("SELECT id,title FROM folders WHERE enabled=1")
    return .array(
      rows.filter { (try? require(context, capability: "files", scope: $0["id"]!.string!)) != nil }
        .map(Value.object))
  }
  public func revokeFolder(_ id: String, issuer: Principal = .user) throws {
    guard issuer == .user else {
      throw HostError("denied", "Only user controls can revoke folders")
    }
    try db.execute("UPDATE folders SET enabled=0 WHERE id=?", [.string(id)])
    try audit("folder.revoked", context: RequestContext(.user), detail: ["id": .string(id)])
  }
  func folderURL(_ id: String, context: RequestContext) throws -> URL {
    try require(context, capability: "files", scope: id)
    guard
      let raw = try db.query("SELECT bookmark FROM folders WHERE id=? AND enabled=1", [.string(id)])
        .first?["bookmark"]?.string, let data = Data(base64Encoded: raw)
    else { throw HostError("denied", "Folder authorization is unavailable") }
    var stale = false
    let url = try URL(
      resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
      bookmarkDataIsStale: &stale)
    guard !stale else { throw HostError("denied", "Please reauthorize the moved folder") }
    return url
  }
  public func readFile(_ args: Value, context: RequestContext) throws -> Value {
    let folder = try args.requiredString("folder")
    let path = try args.requiredString("path")
    let url = try folderURL(folder, context: context)
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let (fd, name) = try ConfinedFiles.parent(path, root: url)
    defer { close(fd) }
    guard let bytes = try ConfinedFiles.read(name, fd: fd) else {
      throw HostError("not_found", "File does not exist")
    }
    try propagate(Labels(taint: ["file:" + folder + "/" + path], isPrivate: true), to: context)
    try audit(
      "files.read", context: context,
      detail: [
        "folder": .string(folder), "path": .string(path), "bytes": .number(Double(bytes.count)),
      ])
    return [
      "text": .string(String(decoding: bytes, as: UTF8.self)),
      "base64": .string(bytes.base64EncodedString()), "hash": .string(ConfinedFiles.hash(bytes)),
      "labels": try Value.from(labels(for: context)),
    ]
  }
  public func writeFile(_ args: Value, context: RequestContext) throws -> Value {
    try mutateFile(args, trash: false, context: context)
  }
  public func trashFile(_ args: Value, context: RequestContext) throws -> Value {
    try mutateFile(args, trash: true, context: context)
  }
  private func mutateFile(_ args: Value, trash: Bool, context: RequestContext) throws -> Value {
    let folder = try args.requiredString("folder")
    let path = try args.requiredString("path")
    let url = try folderURL(folder, context: context)
    guard trash || (args["text"]?.string?.utf8.count ?? Int.max) <= 2_000_000 else {
      throw HostError("invalid_args", "Text must be at most 2 MB")
    }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let (fd, name) = try ConfinedFiles.parent(path, root: url)
    defer { close(fd) }
    let before = try ConfinedFiles.read(name, fd: fd)
    guard !trash || before != nil else { throw HostError("not_found", "File does not exist") }
    let bytes = trash ? nil : Data(args["text"]!.string!.utf8)
    guard (args["expectedHash"]?.string ?? "absent") == ConfinedFiles.hash(before) else {
      throw HostError("conflict", "Read the current file and supply its expectedHash")
    }
    let ticket = try prepareSink(
      action: trash ? "files.trash" : "files.write",
      args: [
        "folder": .string(folder), "path": .string(path),
        "hash": .string(ConfinedFiles.hash(bytes)),
      ], effect: .write, capability: "files", scope: folder, context: context)
    _ = try claimSink(ticket.id, context: context)
    try db.execute(
      "INSERT INTO file_history VALUES (?,?,?,?,?)",
      [
        .string(ticket.id), .string(folder), .string(path),
        before.map { .string($0.base64EncodedString()) } ?? .null,
        .string(ConfinedFiles.hash(bytes)),
      ])
    do {
      try ConfinedFiles.replace(name, fd: fd, bytes: bytes)
      try finishSink(ticket.id, state: "done", result: ["hash": .string(ConfinedFiles.hash(bytes))])
    } catch {
      try? finishSink(
        ticket.id, state: "unknown", result: ["message": .string(error.localizedDescription)])
      throw error
    }
    return ["effectID": .string(ticket.id), "hash": .string(ConfinedFiles.hash(bytes))]
  }
  public func undoFile(_ id: String, context: RequestContext) throws -> Value {
    if try !db.query("SELECT id FROM directory_history WHERE id=?", [.string(id)]).isEmpty {
      return try undoDirectory(id, context: context)
    }
    guard
      let row = try db.query(
        "SELECT h.*,s.context FROM file_history h JOIN sink_operations s ON h.effect_id=s.id WHERE h.effect_id=? AND s.state IN ('done','unknown')",
        [.string(id)]
      ).first
    else { throw HostError("conflict", "No reversible file operation") }
    try requireEffectOwner(row["context"]!.string!, context: context)
    let folder = row["folder"]!.string!
    let path = row["path"]!.string!
    let url = try folderURL(folder, context: context)
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let (fd, name) = try ConfinedFiles.parent(path, root: url)
    defer { close(fd) }
    let current = try ConfinedFiles.read(name, fd: fd)
    guard ConfinedFiles.hash(current) == row["after_hash"]?.string else {
      throw HostError("conflict", "File has changed since this operation")
    }
    let before = row["before_data"]?.string.flatMap { Data(base64Encoded: $0) }
    let ticket = try prepareSink(
      action: "files.undo",
      args: ["effectID": .string(id), "folder": .string(folder), "path": .string(path)],
      effect: .write, capability: "files", scope: folder, context: context)
    _ = try claimSink(ticket.id, context: context)
    try db.execute(
      "INSERT INTO file_history VALUES (?,?,?,?,?)",
      [
        .string(ticket.id), .string(folder), .string(path),
        current.map { .string($0.base64EncodedString()) } ?? .null,
        .string(ConfinedFiles.hash(before)),
      ])
    do {
      try ConfinedFiles.replace(name, fd: fd, bytes: before)
      try finishSink(ticket.id, state: "done", result: [:])
      try finishSink(id, state: "compensated", result: ["undo": .string(ticket.id)])
    } catch {
      try? finishSink(
        ticket.id, state: "unknown", result: ["message": .string(error.localizedDescription)])
      throw error
    }
    return ["effectID": .string(ticket.id), "hash": .string(ConfinedFiles.hash(before))]
  }
  public func consumeQuota(
    _ service: String, limit: Int, capability: String = "service", context: RequestContext
  ) throws {
    try authorize(context, capability: capability, scope: service)
    let holder = try initiator(of: context).id
    let day = String(Self.now().prefix(10))
    let count =
      try db.query(
        "SELECT count FROM service_usage WHERE holder=? AND service=? AND day=?",
        [.string(holder), .string(service), .string(day)]
      ).first?["count"]?.int ?? 0
    guard count < limit else { throw HostError("rate_limited", "Daily service quota exceeded") }
    try db.execute(
      "INSERT INTO service_usage VALUES (?,?,?,1) ON CONFLICT(holder,service,day) DO UPDATE SET count=count+1",
      [.string(holder), .string(service), .string(day)])
  }
}
