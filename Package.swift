// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AgentOSKit",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "AgentOSCore", targets: ["AgentOSCore"]),
    .library(name: "AgentOSRuntime", targets: ["AgentOSRuntime"]),
  ],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "AgentOSCore", dependencies: ["CSQLite"]),
    .target(
      name: "AgentOSRuntime", dependencies: ["AgentOSCore"], resources: [.process("Resources/sdk.js"), .process("Resources/host.js"), .copy("Resources/native-sdk.txt"), .copy("Resources/Library")]),
    .executableTarget(name: "RuntimeChecks", dependencies: ["AgentOSRuntime"]),
    .executableTarget(name: "aos"),
    .executableTarget(name: "VMChecks", dependencies: ["AgentOSRuntime"]),
    .executableTarget(name: "NativeChecks", dependencies: ["AgentOSRuntime"]),
    .testTarget(name: "AgentOSCoreTests", dependencies: ["AgentOSCore"]),
  ]
)
