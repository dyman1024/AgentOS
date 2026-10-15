import AgentOSCore
import Foundation

@MainActor public protocol CoreHost: AnyObject {
  var app: InstalledApp { get }
  var instanceID: String { get }
  var context: RequestContext? { get set }
  var lastUsed: Date { get }
  var invalidated: Bool { get }
  var onRequest: ((String, Value, RequestContext) async throws -> Value)? { get set }
  var onSubscription: ((String) async throws -> Void)? { get set }
  func ready() async throws
  func invoke(kind: String, name: String, args: Value) async throws -> Value
  func close()
}
extension WebInstance: CoreHost {}
