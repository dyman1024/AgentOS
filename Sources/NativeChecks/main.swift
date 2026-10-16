import AgentOSCore
import AgentOSRuntime
import AppKit
import Foundation

@main struct NativeChecks {
  @MainActor static func main() {
    setvbuf(stdout, nil, _IONBF, 0)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
      do {
        try await run()
        print("PASS: native compiler, protocol and sandbox")
        exit(0)
      } catch {
        fputs("FAIL: \(error)\n", stderr)
        exit(1)
      }
    }
    app.run()
  }
  @MainActor static func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw HostError("test_failed", message) }
    print("✓ " + message)
  }
  @MainActor static func run() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agentos-native-test-" + UUID().uuidString)
    let kernel = try Kernel(root: root)
    let runtime = RuntimeCoordinator(kernel: kernel)
    let user = RequestContext(.user)
    defer {
      runtime.closeAll()
      if ProcessInfo.processInfo.environment["AGENTOS_KEEP_TEST_ROOT"] != "1" {
        try? FileManager.default.removeItem(at: root)
      }
    }
    let app = try await kernel.createApp(
      title: "Native test", namespace: "nativecheck", context: user)
    let directory = try await kernel.sourceDirectory(app.id)
    let manifest: Value = [
      "schema": "agentos.app/1", "id": .string(app.id), "version": "1.0.0+1",
      "title": "Native test", "runtime": ["kind": "macos-native"], "permissions": [:],
    ]
    let source = """
      import Foundation
      import Darwin
      @main struct NativeApp {
        static func main() throws {
          try AgentOSNative.start(tools: [
            "echo": { args in if args["exit"] as? Bool == true { _exit(17) }; return args },
            "probe": { args in
              let outside = FileManager.default.contents(atPath: args["path"] as? String ?? "/no-file") != nil
              let fd = socket(AF_INET, SOCK_STREAM, 0)
              var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(443).bigEndian; inet_pton(AF_INET, "1.1.1.1", &address.sin_addr)
              let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
              if fd >= 0 { close(fd) }
              return ["outsideReadable": outside, "networkConnected": connected == 0]
            },
            "save": { args in try AgentOSNative.call("data.put", ["collection": "notes", "record": ["title": args["title"] ?? "native"]]) }
          ])
          RunLoop.main.run()
        }
      }
      """
    func tool(_ name: String) -> Value {
      [
        "name": .string(name), "input": ["type": "object"], "output": ["type": "object"],
        "examples": [["input": [:]]],
      ]
    }
    let definition: Value = [
      "schema": "agentos.interface/1", "id": "nativecheck", "version": "1.0.0",
      "tools": .array(["echo", "probe", "save"].map(tool)),
      "data": [["collection": "notes", "access": "rw"]],
    ]
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try Data(source.utf8).write(to: directory.appendingPathComponent("Sources/main.swift"))
    try manifest.encoded().write(to: directory.appendingPathComponent("manifest.json"))
    try definition.encoded().write(to: directory.appendingPathComponent("interface/interface.json"))
    let tests: Value = [
      ["name": "echo", "tool": "echo", "args": ["value": "native"], "expect": ["value": "native"]],
      [
        "name": "sandbox", "tool": "probe", "args": [:],
        "expect": ["outsideReadable": false, "networkConnected": false],
      ],
      [
        "name": "bridge", "tool": "save", "args": ["title": "isolated"],
        "expect": ["title": "isolated"],
      ],
    ]
    try tests.encoded().write(to: directory.appendingPathComponent("tests/contract.json"))
    let result = try await runtime.commit(app.id, context: user)
    try check(
      result["tests"]?["pass"] == true,
      "native source compiles under host sandbox and passes isolated contracts")
    let sentinel = root.appendingPathComponent("private.txt")
    try Data("private sentinel".utf8).write(to: sentinel)
    let probe = try await runtime.call(
      "nativecheck.probe", args: ["path": .string(sentinel.path)], caller: user)
    try check(
      probe["outsideReadable"] == false && probe["networkConnected"] == false,
      "native process cannot read host data or directly connect to network")
    let record = try await runtime.call(
      "nativecheck.save", args: ["title": "native roundtrip"], caller: user)
    try check(
      record["title"] == "native roundtrip",
      "native tool calls shared data through bound host context")
    var terminated = false
    do { _ = try await runtime.call("nativecheck.echo", args: ["exit": true], caller: user) } catch
    { terminated = true }
    let count = try await kernel.query("notes", context: user).count
    try check(
      terminated && count == 1, "unexpected native process exit leaves host and data intact")
    let restarted = try await runtime.call(
      "nativecheck.echo", args: ["value": "restarted"], caller: user)
    try check(restarted["value"] == "restarted", "native core restarts on the next call")
    runtime.closeAll()
    try await kernel.shutdown()
  }
}
