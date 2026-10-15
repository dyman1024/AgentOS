import AgentOSCore
import Foundation

public enum RuntimeResources {
  public static func libraryFile(_ name: String) throws -> URL {
    guard let root = Bundle.module.url(forResource: "Library", withExtension: nil) else {
      throw HostError("unavailable", "UI library missing; run make ui-kit")
    }
    return try SafePath.resolve(name, under: root)
  }
}
