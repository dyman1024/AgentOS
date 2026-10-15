import AgentOSCore
import AgentOSRuntime
import AppKit
import CryptoKit
import Foundation

@main struct VMChecks {
  @MainActor static func main() {
    setvbuf(stdout, nil, _IONBF, 0)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
      do {
        try await run()
        print(
          "PASS: VM isolation and "
            + (ProcessInfo.processInfo.environment["VM_COLD_RESTORE"] == "1"
              ? "cold disk checkpoint (memory restoration not tested)"
              : "memory snapshot integration"))
        exit(0)
      } catch {
        fputs("FAIL: \(error)\n", stderr)
        exit(1)
      }
    }
    app.run()
  }
  @MainActor static func check(_ value: Bool, _ message: String) throws {
    guard value else { throw HostError("test_failed", message) }
    print("✓ " + message)
  }
  @MainActor static func run() async throws {
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--restore-only" {
      let directory = URL(fileURLWithPath: CommandLine.arguments[2])
      let vm = WorkbenchVM(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
      let id = try FileManager.default.contentsOfDirectory(
        atPath: directory.appendingPathComponent("snapshots").path
      ).first!
      try await vm.restore(id)
      let restored = try await vm.execute("fs.read", args: ["path": "snapshot.txt"])
      try check(restored["text"] == "before", "snapshot restored in a fresh process")
      try await vm.stop()
      return
    }
    guard CommandLine.arguments.count == 3 else {
      throw HostError("invalid_args", "VMChecks <kernel> <ext4-image>")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agentos-vm-check-" + UUID().uuidString)
    let vm = WorkbenchVM(directory: root.appendingPathComponent("vm"))
    defer {
      if ProcessInfo.processInfo.environment["VM_KEEP"] != "1" {
        try? FileManager.default.removeItem(at: root)
      }
    }
    if ProcessInfo.processInfo.environment["VM_KEEP"] == "1" { print("Debug root: \(root.path)") }
    try vm.install(
      kernel: URL(fileURLWithPath: CommandLine.arguments[1]),
      image: URL(fileURLWithPath: CommandLine.arguments[2]))
    let kernel = try Kernel(root: root)
    let network = NetworkGateway(kernel: kernel)
    _ = try await kernel.grant(holder: .core("vmcheck"), capability: "net", scope: "example.com")
    let run = try await kernel.startRun(session: "vm", initiator: .core("vmcheck"), duration: 600)
    let context = RequestContext(.run(run), runID: run)
    try await kernel.propagate(Labels(taint: ["vm"]), to: context)
    vm.onHostRequest = { name, args in
      guard name == "net.fetch" else { throw HostError("denied", "Method is not permitted") }
      return try await network.fetch(args, context: context)
    }
    try await vm.start()
    print("VM ready")
    let initial = try await vm.execute("ping", args: [:])
    print("Guest status: \(try initial.text())")
    let hardware = try await vm.execute(
      "exec",
      args: [
        "cmd":
          "python3 -c \"import os; print(sum(os.path.exists('/sys/class/net/'+n+'/device') for n in os.listdir('/sys/class/net')))\""
      ])
    try check(
      initial["networkInterfaces"]!.array!.contains("lo")
        && hardware["stdout"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "0",
      "guest has no hardware network device; kernel virtual interfaces have no host uplink")
    let command = try await vm.execute(
      "exec", args: ["cmd": "printf 'workbench-ok'; python3 --version; node --version"])
    try check(
      command["exitCode"] == 0 && command["stdout"]!.string!.contains("workbench-ok"),
      "Python, Node and shell execute over vsock")
    let blocked = try await vm.execute(
      "exec",
      args: ["cmd": "python3 -c \"import socket; socket.create_connection(('1.1.1.1',443),2)\""])
    try check(blocked["exitCode"] != 0, "direct outbound socket cannot bypass host policy")
    if ProcessInfo.processInfo.environment["VM_SKIP_NETWORK"] != "1" {
      let denied = try await vm.execute(
        "exec", args: ["cmd": "aos net.fetch '{\"url\":\"https://unauthorized.example\"}'"])
      try check(
        denied["stdout"]!.string!.contains("denied"), "vsock egress rejects domains without a grant"
      )
      let forged = try await vm.execute(
        "exec",
        args: ["cmd": "AOS_RUN_TOKEN=forged aos net.fetch '{\"url\":\"https://example.com\"}'"])
      try check(forged["stdout"]!.string!.contains("denied"), "forged command token is rejected")
      let allowed = try await vm.execute(
        "exec", args: ["cmd": "aos net.fetch '{\"url\":\"https://example.com\"}'"])
      try check(
        allowed["stdout"]!.string!.contains("Example Domain"),
        "authorized HTTPS egress goes through host gateway")
    }
    let service = try await vm.execute(
      "service.start", args: ["name": "test-service", "cmd": "printf service-started; sleep 60"])
    try check(service["running"] == true, "background service starts")
    let status = try await vm.execute("service.status", args: ["name": "test-service"])
    try check(
      status["running"] == true, "background service survives individual command completion")
    _ = try await vm.execute("service.stop", args: ["name": "test-service"])
    try await backendChecks(kernel: kernel, base: vm.directory, root: root)
    if let archive = ProcessInfo.processInfo.environment["VM_OCI_ARCHIVE"] {
      try await backendChecks(
        kernel: kernel, base: vm.directory, root: root, archive: URL(fileURLWithPath: archive))
    }
    try await imageChecks(vm)
    let ephemeral = try vm.ephemeral()
    let isolated = try await ephemeral.execute(
      "exec",
      args: ["cmd": "test ! -e /workspace/snapshot.txt; test ! -e /Users; printf ephemeral-ok"])
    try check(
      isolated["stdout"] == "ephemeral-ok",
      "temporary VM boots from clean base without host folders")
    try await ephemeral.discard()
    try check(
      !FileManager.default.fileExists(atPath: ephemeral.directory.path),
      "temporary VM disk is removed after execution")
    _ = try await vm.execute("fs.write", args: ["path": "snapshot.txt", "text": "before"])
    let snapshot = UUID().uuidString
    _ = try await vm.snapshot(snapshot)
    _ = try await vm.execute("fs.write", args: ["path": "snapshot.txt", "text": "after"])
    try await vm.restore(
      snapshot, cold: ProcessInfo.processInfo.environment["VM_COLD_RESTORE"] == "1")
    let restored = try await vm.execute("fs.read", args: ["path": "snapshot.txt"])
    try check(restored["text"] == "before", "disk and machine snapshot restore prior state")
    try await vm.stop()
    try await kernel.shutdown()
  }
  @MainActor static func imageChecks(_ vm: WorkbenchVM) async throws {
    func artifact(_ file: URL) throws -> Value {
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      var digest = SHA256()
      var bytes = 0
      while let chunk = try handle.read(upToCount: 1_000_000), !chunk.isEmpty {
        digest.update(data: chunk)
        bytes += chunk.count
      }
      return [
        "url": .string("https://images.example.com/" + file.lastPathComponent),
        "bytes": .number(Double(bytes)),
        "sha256": .string(digest.finalize().map { String(format: "%02x", $0) }.joined()),
      ]
    }
    let key = Curve25519.Signing.PrivateKey()
    let kernel = vm.directory.appendingPathComponent("kernel")
    let disk = vm.directory.appendingPathComponent("base.ext4")
    let payload = try Value.object([
      "version": "1.0.0", "architecture": "arm64", "os": "linux", "kernel": artifact(kernel),
      "disk": artifact(disk),
    ]).encoded()
    let envelope: Value = [
      "schema": "agentos.workbench/1", "payload": .string(payload.base64EncodedString()),
      "signature": .string(try key.signature(for: payload).base64EncodedString()),
    ]
    let release = try WorkbenchImage(
      manifest: envelope.encoded(),
      trustedPublicKey: key.publicKey.rawRepresentation.base64EncodedString())
    _ = try await vm.execute(
      "fs.write", args: ["path": "kept-across-base-update", "text": "persistent"])
    try await vm.installVerified(release, kernel: kernel, image: disk)
    let artifacts = try vm.baseArtifacts()
    try check(
      artifacts.image != disk, "signed base image update selects a separate immutable image")
    let kept = try await vm.execute("fs.read", args: ["path": "kept-across-base-update"])
    try check(
      kept["text"] == "persistent", "base image update preserves the running persistent guest disk")
    do {
      try await vm.installVerified(release, kernel: kernel, image: disk)
      throw HostError("test_failed", "Image version replay was accepted")
    } catch let error as HostError {
      try check(error.code == "conflict", "base image version replay or downgrade is rejected")
    }
  }
  @MainActor static func backendChecks(kernel: Kernel, base: URL, root: URL, archive: URL? = nil)
    async throws
  {
    let user = RequestContext(.user)
    let runtime = RuntimeCoordinator(kernel: kernel)
    runtime.backends = AppBackendRuntime(
      base: base, storage: root.appendingPathComponent("app-backends"))
    runtime.confirm = { _, _ in true }
    let namespace = archive == nil ? "backendcheck" : "ocicheck"
    let app = try await kernel.createApp(
      title: archive == nil ? "Node backend" : "OCI backend", namespace: namespace, context: user)
    let source = try await kernel.sourceDirectory(app.id)
    var manifest = app.manifest.object!
    manifest["runtime"] = [
      "kind": "web", "core": "core.js", "ui": "ui/index.html",
      "backend": ["language": "node", "entry": "server.cjs", "files": ["server.cjs"]],
    ]
    manifest["permissions"] = ["network": [], "services": ["backend.call"], "files": []]
    if let archive {
      var declaration = manifest["runtime"]!.object!
      declaration["backend"] = [
        "language": "oci", "entry": "backend.oci.tar", "files": ["backend.oci.tar"],
      ]
      manifest["runtime"] = .object(declaration)
      try FileManager.default.copyItem(
        at: archive, to: source.appendingPathComponent("backend.oci.tar"))
    }
    try Value.object(manifest).encoded().write(to: source.appendingPathComponent("manifest.json"))
    let tools: Value = .array(
      ["sum", "count"].map { name in
        [
          "name": .string(name), "description": .string(name), "input": ["type": "object"],
          "output": ["type": "number"], "examples": [["input": [:]]],
        ]
      })
    let interface: Value = [
      "schema": "agentos.interface/1", "id": .string(app.namespace), "version": "1.0.0",
      "tools": tools,
    ]
    try interface.encoded().write(to: source.appendingPathComponent("interface/interface.json"))
    try Data(
      "for(const method of ['sum','count'])agentos.tools.register(method,a=>agentos.backend.call(method,a));"
        .utf8
    ).write(to: source.appendingPathComponent("core.js"))
    try Data(
      """
      const readline=require('readline');let count=0;
      readline.createInterface({input:process.stdin}).on('line',line=>{
        const r=JSON.parse(line);let result=r.method==='count'?++count:Number(r.args.a||0)+Number(r.args.b||0);
        process.stdout.write(JSON.stringify({id:r.id,result})+'\\n');
      });
      """.utf8
    ).write(to: source.appendingPathComponent("server.cjs"))
    let tests: Value = [
      ["name": "sum", "tool": "sum", "args": ["a": 20, "b": 22], "expect": 42],
      ["name": "counter", "tool": "count", "expect": 1],
    ]
    try tests.encoded().write(to: source.appendingPathComponent("tests/contract.json"))
    _ = try await runtime.commit(app.id, context: user)
    try check(
      try await runtime.call(namespace + ".count", args: [:], caller: user) == 1,
      namespace + ": contracts run in a disposable VM; live state begins clean")
    try check(
      try await runtime.call(namespace + ".count", args: [:], caller: user) == 2,
      namespace + ": backend process persists across tool calls without an open UI")
    let context = RequestContext(.core(app.id), instanceID: runtime.cores[app.id]!.instanceID)
    try check(
      try await kernel.labels(for: context).isPrivate,
      "backend output retains conservative private and external-source labels")
    for grant in try await kernel.grants().array ?? []
    where grant["holder"] == .string(Principal.core(app.id).id) && grant["scope"] == "backend.call"
    {
      try await kernel.revoke(grant["id"]!.string!)
    }
    do {
      _ = try await runtime.call(namespace + ".count", args: [:], caller: user)
      throw HostError("test_failed", "Backend reused a revoked grant")
    } catch let error as HostError {
      try check(error.code == "denied", "backend grant revocation takes effect before dispatch")
    }
    runtime.closeAll()
    await runtime.backends?.closeAll()
  }

}
