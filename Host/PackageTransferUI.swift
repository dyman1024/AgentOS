import AgentOSCore
import AppKit
import CryptoKit
import Foundation

extension AppModel {
  func exportApp(_ id: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Application.agentpkg"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    Task {
      do {
        let key: Curve25519.Signing.PrivateKey
        if let encoded = try settings.credential("package-signing"),
          let data = Data(base64Encoded: encoded)
        {
          key = try .init(rawRepresentation: data)
        } else {
          key = .init()
          try settings.saveCredential(
            "package-signing", value: key.rawRepresentation.base64EncodedString())
        }
        let data = try await kernel.exportPackage(
          id, signingKey: key.rawRepresentation, context: RequestContext(.user))
        try data.write(to: destination, options: .atomic)
        status = "应用已签名导出"
      } catch { self.error = error.localizedDescription }
    }
  }
  func importApp() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "选择签名的 .agentpkg 应用包"
    guard panel.runModal() == .OK, let source = panel.url else { return }
    Task {
      do {
        guard try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 225_000_000 else {
          throw HostError("too_large", "应用包超过大小限制")
        }
        let bytes = try Data(contentsOf: source)
        let verified = try PackageArchive.verify(bytes)
        guard
          await confirm(
            "导入新应用；签名用于识别作者，不能保证代码安全。安装仍需契约测试和新的权限。", ["签名指纹": .string(verified.fingerprint)])
        else { return }
        let app = try await kernel.importPackage(
          bytes, acceptedFingerprint: verified.fingerprint, context: RequestContext(.user))
        _ = try await runtime.commit(app.id, context: RequestContext(.user))
        await refresh()
        await open(app.id)
      } catch {
        self.error = error.localizedDescription
        await refresh()
      }
    }
  }
}
