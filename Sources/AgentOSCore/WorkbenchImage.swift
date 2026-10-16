import CryptoKit
import Foundation

/// A distributor-signed manifest. Trust is anchored in a separately configured Ed25519 public key.
public struct WorkbenchImage: Sendable {
  public let version: String
  public let kernel: Artifact
  public let disk: Artifact
  public let fingerprint: String
  public struct Artifact: Sendable {
    public let url: String
    public let sha256: String
    public let bytes: Int
    init(_ value: Value, maximum: Int) throws {
      url = try value.requiredString("url")
      _ = try HTTPClient.validateURL(url)
      sha256 = try value.requiredString("sha256")
      guard sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
        let size = value["bytes"]?.int, size > 0, size <= maximum
      else { throw HostError("invalid_package", "Invalid image artifact size or digest") }
      bytes = size
    }
    public func verify(_ file: URL) throws {
      let values = try file.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == bytes
      else {
        throw HostError("invalid_package", "Image artifact size changed")
      }
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      var digest = SHA256()
      var total = 0
      while let chunk = try handle.read(upToCount: 1_000_000), !chunk.isEmpty {
        total += chunk.count
        guard total <= bytes else { throw HostError("invalid_package", "Image artifact grew") }
        digest.update(data: chunk)
      }
      guard total == bytes, digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256
      else {
        throw HostError("invalid_package", "Image artifact digest mismatch")
      }
    }
  }
  public init(manifest: Data, trustedPublicKey: String) throws {
    guard manifest.count <= 100_000,
      let rawKey = Data(base64Encoded: trustedPublicKey), rawKey.count == 32
    else { throw HostError("invalid_args", "A trusted Ed25519 public key is required") }
    let envelope = try Value.parse(String(decoding: manifest, as: UTF8.self))
    guard envelope["schema"] == "agentos.workbench/1",
      let payload = Data(base64Encoded: envelope["payload"]?.string ?? ""),
      let signature = Data(base64Encoded: envelope["signature"]?.string ?? ""),
      try Curve25519.Signing.PublicKey(rawRepresentation: rawKey).isValidSignature(
        signature, for: payload)
    else { throw HostError("invalid_package", "Workbench manifest signature is invalid") }
    let value = try Value.parse(String(decoding: payload, as: UTF8.self))
    version = try value.requiredString("version")
    guard Version(version) != nil, value["architecture"] == "arm64", value["os"] == "linux" else {
      throw HostError("invalid_package", "Expected a versioned linux/arm64 image")
    }
    kernel = try Artifact(value["kernel"] ?? .null, maximum: 100_000_000)
    disk = try Artifact(value["disk"] ?? .null, maximum: 8_000_000_000)
    fingerprint = SHA256.hash(data: rawKey).map { String(format: "%02x", $0) }.joined()
  }
}
