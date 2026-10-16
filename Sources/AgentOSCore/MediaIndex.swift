import Foundation

extension Kernel {
  public func indexMedia(
    folder: String, path: String, title: String, kind: String, bytes: Int, context: RequestContext
  ) throws -> Record {
    try require(context, capability: "service", scope: "media.scan")
    _ = try folderURL(folder, context: context)
    guard ["music", "movie", "episode"].contains(kind), bytes >= 0 else {
      throw HostError("invalid_args", "Invalid media item")
    }
    let id = Self.digest(Data((folder + "/" + path).utf8))
    let old = try readRecord("media", id: id)
    var fields = old?.fields ?? [:]
    fields["folder"] = .string(folder)
    fields["path"] = .string(path)
    fields["title"] = .string(title)
    fields["kind"] = .string(kind)
    fields["bytes"] = .number(Double(bytes))
    if old?.fields == fields, old?.deleted == false { return old! }
    return try db.transaction {
      try apply(
        Mutation("media", id: id, fields: fields, expectedRevision: old?.rev), context: context,
        restoredLabels: labels(for: context).union(
          Labels(taint: ["file:" + folder], isPrivate: true))
      ).record
    }
  }
  public func saveMediaProgress(
    folder: String, path: String, seconds: Double, context: RequestContext
  ) throws {
    try require(context, capability: "service", scope: "media.play")
    _ = try folderURL(folder, context: context)
    guard seconds.isFinite, seconds >= 0 else {
      throw HostError("invalid_args", "Invalid progress")
    }
    let id = Self.digest(Data((folder + "/" + path).utf8))
    guard let old = try readRecord("media", id: id), !old.deleted else { return }
    var fields = old.fields
    fields["progress"] = .number(seconds)
    _ = try db.transaction {
      try apply(
        Mutation("media", id: id, fields: fields, expectedRevision: old.rev), context: context,
        restoredLabels: old.labels)
    }
  }
}
