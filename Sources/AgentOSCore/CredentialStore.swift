import Foundation
import LocalAuthentication
import Security

/// Keeps credentials in the existing host Keychain namespace. Never treats denied reads as absence.
public struct CredentialStore: Sendable {
  private static let queue = DispatchQueue(label: "dev.agentos.credentials", qos: .userInitiated)
  public let service: String
  public init(service: String = "dev.agentos.AgentOSRebuild") { self.service = service }

  public func read(_ account: String, allowInteraction: Bool = true) throws -> String? {
    var request = query(account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    if !allowInteraction {
      let context = LAContext()
      context.interactionNotAllowed = true
      request[kSecUseAuthenticationContext as String] = context
    }
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    return try Self.decode(status: status, data: result as? Data)
  }

  public func contains(_ account: String) throws -> Bool {
    // Metadata only: opening Settings must not decrypt a secret or request Keychain access.
    let status = SecItemCopyMatching(query(account) as CFDictionary, nil)
    if status == errSecItemNotFound { return false }
    guard status == errSecSuccess else { throw Self.failure(status, operation: "查询") }
    return true
  }

  public func containsAsync(_ account: String) async throws -> Bool {
    try await Self.perform { try contains(account) }
  }
  public func readAsync(_ account: String) async throws -> String? {
    try await Self.perform { try read(account) }
  }
  public func saveAsync(_ account: String, value: String) async throws {
    try await Self.perform { try save(account, value: value) }
  }
  static func perform<T: Sendable>(
    timeout: TimeInterval = 20, _ operation: @escaping @Sendable () throws -> T
  ) async throws -> T {
    let pending = CredentialOperation<T>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending.begin(continuation)
        Self.queue.async {
          guard !pending.finished else { return }
          pending.finish(Result { try operation() })
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
          pending.finish(
            .failure(HostError("keychain_timeout", "钥匙串操作超时。请处理系统钥匙串提示；若刚更新开发版，请退出并重新打开后检查保存状态。")))
        }
      }
    } onCancel: {
      pending.finish(.failure(CancellationError()))
    }
  }

  static func decode(status: OSStatus, data: Data?) throws -> String? {
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw failure(status, operation: "读取") }
    guard let data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
      throw HostError("keychain_error", "钥匙串中的凭据为空或格式损坏，请重新保存。")
    }
    return value
  }

  public func save(_ account: String, value: String) throws {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw HostError("invalid_args", "请输入凭据。") }
    let data = Data(value.utf8)
    var request = query(account)
    var status = SecItemUpdate(
      request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      request[kSecValueData as String] = data
      request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(request as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw Self.failure(status, operation: "保存") }
    // A successful write alone does not prove the current host can consume the credential.
    guard try read(account) == value else {
      throw HostError("keychain_error", "凭据写入后读取校验失败，请重新保存。")
    }
  }

  public func remove(_ account: String) throws {
    let status = SecItemDelete(query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Self.failure(status, operation: "删除")
    }
  }

  private func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  private static func failure(_ status: OSStatus, operation: String) -> HostError {
    HostError(
      "keychain_error",
      "钥匙串\(operation)失败（\(status)）。请解锁 Mac，并允许 AgentOS 访问钥匙串；若刚更新了开发版，请退出并重新打开应用后重试。",
      details: ["status": .number(Double(status))])
  }
}

// SecItem calls are synchronous and may wait for SecurityAgent. Resume the UI once on cancellation
// or timeout, without abandoning a continuation or allowing a late result to replace current state.
private final class CredentialOperation<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Error>?
  private var result: Result<T, Error>?
  private var done = false
  var finished: Bool { lock.withLock { done } }
  func begin(_ continuation: CheckedContinuation<T, Error>) {
    let completed = lock.withLock {
      if done { return result }
      self.continuation = continuation
      return nil as Result<T, Error>?
    }
    if let completed { continuation.resume(with: completed) }
  }
  func finish(_ result: Result<T, Error>) {
    let continuation = lock.withLock {
      guard !done else { return nil as CheckedContinuation<T, Error>? }
      done = true
      if self.continuation == nil { self.result = result }
      let continuation = self.continuation
      self.continuation = nil
      return continuation
    }
    continuation?.resume(with: result)
  }
}
