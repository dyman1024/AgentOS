import Darwin
import Foundation

/// The host retains this descriptor; applications receive no path or descriptor.
public final class AuthorizedFile: @unchecked Sendable {
  private let descriptor: Int32
  private let lock = NSLock()
  public let length: Int64
  public let filename: String
  init(descriptor: Int32, length: Int64, filename: String) {
    self.descriptor = descriptor
    self.length = length
    self.filename = filename
  }
  deinit { Darwin.close(descriptor) }
  public func read(offset: Int64, count: Int) throws -> Data {
    guard offset >= 0, offset <= length, count >= 0, count <= 1024 * 1024 else {
      throw HostError("invalid_args", "Invalid file range")
    }
    lock.lock()
    defer { lock.unlock() }
    var buffer = [UInt8](repeating: 0, count: min(count, Int(length - offset)))
    let n = pread(descriptor, &buffer, buffer.count, off_t(offset))
    guard n >= 0 else { throw HostError("io_error", "File range read failed") }
    return Data(buffer.prefix(n))
  }
}
extension Kernel {
  public func checkFolder(_ id: String, context: RequestContext) throws {
    _ = try folderURL(id, context: context)
  }
  public func openAuthorizedFile(_ args: Value, context: RequestContext) throws -> AuthorizedFile {
    let folder = try args.requiredString("folder")
    let path = try args.requiredString("path")
    let url = try folderURL(folder, context: context)
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let (parent, name) = try ConfinedFiles.parent(path, root: url)
    defer { close(parent) }
    let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw HostError("denied", "Cannot open file") }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      close(fd)
      throw HostError("denied", "Only regular files are supported")
    }
    let stream = AuthorizedFile(descriptor: fd, length: info.st_size, filename: name)
    try propagate(Labels(taint: ["file:" + folder + "/" + path], isPrivate: true), to: context)
    try audit(
      "files.openStream", context: context,
      detail: ["folder": .string(folder), "path": .string(path)])
    return stream
  }
  public func listFiles(_ args: Value, context: RequestContext) throws -> Value {
    let folder = try args.requiredString("folder")
    let path = args["path"]?.string ?? ""
    let url = try folderURL(folder, context: context)
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let fd: Int32
    if path.isEmpty {
      fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    } else {
      let (parent, name) = try ConfinedFiles.parent(path, root: url)
      defer { close(parent) }
      fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    }
    guard fd >= 0, let directory = fdopendir(fd) else {
      if fd >= 0 { close(fd) }
      throw HostError("denied", "Directory is unavailable")
    }
    defer { closedir(directory) }
    var result: [Value] = []
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }
      guard result.count < 2000 else {
        throw HostError("too_large", "Directory exceeds 2000 entries; select a smaller folder")
      }
      var info = stat()
      guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
      let type = info.st_mode & S_IFMT
      result.append([
        "name": .string(name), "directory": .bool(type == S_IFDIR),
        "symlink": .bool(type == S_IFLNK), "bytes": .number(Double(info.st_size)),
      ])
    }
    try propagate(Labels(taint: ["file:" + folder], isPrivate: true), to: context)
    return .array(result.sorted { ($0["name"]?.string ?? "") < ($1["name"]?.string ?? "") })
  }
}
