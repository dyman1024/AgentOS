import AgentOSCore
import Foundation

extension WorkbenchVM {
  public func baseArtifacts() throws -> (kernel: URL, image: URL) {
    let pointer = directory.appendingPathComponent("base-image.json")
    guard FileManager.default.fileExists(atPath: pointer.path) else {
      return (
        directory.appendingPathComponent("kernel"), directory.appendingPathComponent("base.ext4")
      )
    }
    let value = try Value.parse(String(contentsOf: pointer, encoding: .utf8))
    let id = try value.requiredString("id")
    guard UUID(uuidString: id) != nil else {
      throw HostError("invalid_package", "Invalid base image pointer")
    }
    let location = directory.appendingPathComponent("images/" + id)
    return (location.appendingPathComponent("kernel"), location.appendingPathComponent("disk.ext4"))
  }
  /// Updates are immutable. Existing guest disks remain pinned; newly created guests use the new base.
  public func installVerified(_ release: WorkbenchImage, kernel: URL, image: URL) async throws {
    let pointer = directory.appendingPathComponent("base-image.json")
    if let raw = try? String(contentsOf: pointer, encoding: .utf8),
      let current = try? Value.parse(raw),
      let version = current["version"]?.string, let old = Version(version),
      let new = Version(release.version), new <= old
    {
      throw HostError("conflict", "Base image version must increase")
    }
    try await Task.detached {
      try release.kernel.verify(kernel)
      try release.disk.verify(image)
    }.value
    let fm = FileManager.default
    if !fm.fileExists(atPath: directory.appendingPathComponent("disk.ext4").path) {
      try install(kernel: kernel, image: image)
    }
    let id = UUID().uuidString
    let location = directory.appendingPathComponent("images/" + id)
    try fm.createDirectory(
      at: location, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    do {
      let installedKernel = location.appendingPathComponent("kernel")
      let installedImage = location.appendingPathComponent("disk.ext4")
      try fm.copyItem(at: kernel, to: installedKernel)
      try fm.copyItem(at: image, to: installedImage)
      try await Task.detached {
        try release.kernel.verify(installedKernel)
        try release.disk.verify(installedImage)
      }.value
      let metadata: Value = [
        "id": .string(id), "version": .string(release.version),
        "publisher": .string(release.fingerprint),
      ]
      try metadata.encoded().write(to: pointer, options: .atomic)
    } catch {
      try? fm.removeItem(at: location)
      throw error
    }
  }
}
