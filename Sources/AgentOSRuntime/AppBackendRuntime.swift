import AgentOSCore
import Foundation

/// Each backend has its own networkless VM and persistent guest disk. No host bridge token is issued.
@MainActor public final class AppBackendRuntime {
  private struct Entry {
    let vm: WorkbenchVM
    var version: String
    var used: Date
  }
  private let base: URL, storage: URL
  private var entries: [String: Entry] = [:]
  private var busy: Set<String> = []
  public init(base: URL, storage: URL) {
    self.base = base
    self.storage = storage
  }
  public func isolated(storage: URL) -> AppBackendRuntime {
    AppBackendRuntime(base: base, storage: storage)
  }
  public var hasActiveWork: Bool { !busy.isEmpty }
  public func closeAll() async {
    for entry in entries.values { try? await entry.vm.stop() }
    entries = [:]
  }
  public func idle() async {
    for (id, entry) in entries
    where !busy.contains(id) && Date().timeIntervalSince(entry.used) > 300 {
      try? await entry.vm.suspend()
    }
  }
  public func call(app: InstalledApp, directory: URL, method: String, args: Value) async throws
    -> Value
  {
    guard UUID(uuidString: app.id) != nil, Version(app.version) != nil,
      !method.isEmpty, method.count <= 128, try args.encoded().count <= 900000,
      let definition = app.manifest["runtime"]?["backend"],
      let language = definition["language"]?.string, ["python", "node", "oci"].contains(language),
      let paths = definition["files"]?.array?.compactMap(\.string), !paths.isEmpty,
      paths.count <= 100,
      paths.contains(try definition.requiredString("entry"))
    else { throw HostError("invalid_package", "Invalid backend declaration") }
    guard busy.insert(app.id).inserted else {
      throw HostError("conflict", "Application backend is busy")
    }
    defer { busy.remove(app.id) }
    if entries[app.id] == nil {
      if entries.count >= 2 {
        guard
          let victim = entries.filter({ !busy.contains($0.key) }).min(by: {
            $0.value.used < $1.value.used
          })
        else {
          throw HostError("unavailable", "Both backend VM slots are occupied")
        }
        try await victim.value.vm.stop()
        entries[victim.key] = nil
      }
      let vm = WorkbenchVM(directory: storage.appendingPathComponent(app.id))
      if !FileManager.default.fileExists(atPath: vm.directory.appendingPathComponent("kernel").path)
      {
        let artifacts = try WorkbenchVM(directory: base).baseArtifacts()
        try vm.install(
          kernel: artifacts.kernel,
          image: artifacts.image)
      }
      entries[app.id] = Entry(vm: vm, version: "", used: Date())
    }
    let vm = entries[app.id]!.vm
    do {
      if entries[app.id]!.version != app.version {
        _ = try await vm.execute("backend.stop", args: [:])
        var total = 0
        for path in paths {
          let file = try SafePath.resolve(path, under: directory)
          if language == "oci" {
            guard paths.count == 1 else {
              throw HostError("invalid_package", "An OCI backend has exactly one image archive")
            }
            try await vm.copyArchive(file, to: "packages/" + app.version + "/" + path)
            continue
          }
          guard
            try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]).isRegularFile
              == true,
            try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= 1_000_000
          else {
            throw HostError("too_large", "Backend files must be regular UTF-8 files up to 1 MB")
          }
          let bytes = try Data(contentsOf: file)
          total += bytes.count
          guard total <= 2_000_000, let text = String(data: bytes, encoding: .utf8) else {
            throw HostError("too_large", "Backend source exceeds 2 MB or is not UTF-8")
          }
          _ = try await vm.execute(
            "fs.write",
            args: ["path": .string("packages/" + app.version + "/" + path), "text": .string(text)])
        }
        _ = try await vm.execute(
          "backend.start",
          args: [
            "language": .string(language),
            "entry": .string("packages/" + app.version + "/" + definition.requiredString("entry")),
          ])
        entries[app.id]!.version = app.version
      }
      let result = try await vm.execute(
        "backend.invoke", args: ["method": .string(method), "args": args])
      entries[app.id]!.used = Date()
      return result
    } catch {
      // Unknown outcomes are surfaced without automatically invoking the same request again.
      entries[app.id]!.version = ""
      throw error
    }
  }
}
