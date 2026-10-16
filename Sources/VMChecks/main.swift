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
          CommandLine.arguments.contains("--restore-only")
            ? "PASS: fresh host restores disk and process memory"
            : ProcessInfo.processInfo.environment["VM_EXPECT_LOCKED_RESTORE_FAILURE"] == "1"
              ? "PASS: locked restore rejected and latest disk preserved"
              : "PASS: VM isolation and "
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
    if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--restore-only" {
      let directory = URL(fileURLWithPath: CommandLine.arguments[2])
      let vm = WorkbenchVM(directory: directory)
      try await vm.restore(CommandLine.arguments[3])
      let restored = try await vm.execute("fs.read", args: ["path": "snapshot.txt"])
      try check(restored["text"] == "before", "snapshot restored in a fresh process")
      let expected = try Value.parse(
        String(contentsOf: directory.appendingPathComponent("memory-check.json"), encoding: .utf8))
      try await verifyMemory(vm, expected: expected)
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
    try await snapshotChecks(vm)
    try await kernel.shutdown()
  }
  @MainActor static func memory(_ vm: WorkbenchVM, method: String, args: Value = [:]) async throws
    -> Value
  {
    try await vm.execute(
      "backend.invoke", args: ["method": .string(method), "args": args])
  }
  @MainActor static func verifyMemory(_ vm: WorkbenchVM, expected: Value) async throws {
    let actual = try await memory(vm, method: "read")
    try check(
      actual == expected,
      "heap counter, random nonce, PID and boot ID resume without a cold boot")
    let next = try await memory(vm, method: "increment")
    try check(next["counter"] == 42, "restored process continues from its saved heap value")
    try await vm.suspend()
    try check(
      vm.running, "restored processes are not automatically suspended by host idle handling")
  }
  @MainActor static func snapshotChecks(_ vm: WorkbenchVM) async throws {
    let source = """
      import json, os, sys, uuid
      counter = 0
      nonce = str(uuid.uuid4())
      boot = open('/proc/sys/kernel/random/boot_id').read().strip()
      for line in sys.stdin:
          request = json.loads(line)
          if request['method'] == 'set': counter = request['args']['counter']
          if request['method'] == 'increment': counter += 1
          print(json.dumps({'id': request['id'], 'result': {
              'counter': counter, 'nonce': nonce, 'pid': os.getpid(), 'boot': boot
          }}), flush=True)
      """
    _ = try await vm.execute("fs.write", args: ["path": "memory.py", "text": .string(source)])
    _ = try await vm.execute(
      "backend.start", args: ["language": "python", "entry": "memory.py"])
    let expected = try await memory(vm, method: "set", args: ["counter": 41])
    try expected.encoded().write(to: vm.directory.appendingPathComponent("memory-check.json"))
    _ = try await vm.execute("fs.write", args: ["path": "snapshot.txt", "text": "before"])
    let snapshot = UUID().uuidString
    let saving = Task { @MainActor in try await vm.snapshot(snapshot) }
    await Task.yield()
    try check(vm.stats()["checkpointing"] == true, "snapshot owns the VM across suspension points")
    do {
      _ = try await vm.execute("fs.write", args: ["path": "racing.txt", "text": "bad"])
      throw HostError("test_failed", "Write raced a snapshot")
    } catch let error as HostError where error.code == "conflict" {}
    do {
      try await vm.stop()
      throw HostError("test_failed", "Stop raced a snapshot")
    } catch let error as HostError where error.code == "conflict" {}
    _ = try await saving.value
    try check(vm.stats()["checkpointing"] == false, "snapshot releases its lifecycle guard")
    _ = try await vm.execute("fs.write", args: ["path": "snapshot.txt", "text": "after"])
    let changed = try await memory(vm, method: "set", args: ["counter": 99])
    try check(changed["counter"] == 99, "live heap changes after snapshot")
    try await vm.suspend()
    try check(!vm.running, "restore also accepts an idle-paused workbench")
    let cold = ProcessInfo.processInfo.environment["VM_COLD_RESTORE"] == "1"
    if ProcessInfo.processInfo.environment["VM_EXPECT_LOCKED_RESTORE_FAILURE"] == "1" {
      do {
        try await vm.restore(snapshot)
        throw HostError("test_failed", "Expected locked-session failure; verify session state")
      } catch let error as HostError where error.code == "vm_restore_failed" {
        try check(
          error.details["domain"] == "VZErrorDomain" && error.details["code"] == 12
            && error.details["reason"]?.string?.contains("permission denied") == true
            && error.details["diskRestored"] == true,
          "locked restore surfaces VZ permission denial and successful disk rollback")
      }
      try check(!vm.running, "locked memory restore never silently cold boots")
      let latest = try await vm.execute("fs.read", args: ["path": "snapshot.txt"])
      try check(latest["text"] == "after", "locked restore preserves acknowledged writes")
      try await vm.stop()
      return
    }
    try await vm.restore(snapshot, cold: cold)
    let restored = try await vm.execute("fs.read", args: ["path": "snapshot.txt"])
    try check(restored["text"] == "before", "snapshot restores disk contents")
    if cold {
      let boot = try await vm.execute("exec", args: ["cmd": "cat /proc/sys/kernel/random/boot_id"])
      try check(
        boot["stdout"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
          != expected["boot"]?.string,
        "explicit cold restore has a new boot ID and makes no memory continuity claim")
      try await vm.stop()
      return
    }
    try await verifyMemory(vm, expected: expected)
    let forged = try await vm.execute(
      "exec",
      args: ["cmd": "AOS_RUN_TOKEN=forged aos net.fetch '{\"url\":\"https://example.com\"}'"])
    try check(
      forged["stdout"]!.string!.contains("denied"), "restoration still rejects forged host tokens")
    // A damaged encrypted state must not roll the user's disk back or silently cold boot.
    _ = try await vm.execute("fs.write", args: ["path": "snapshot.txt", "text": "latest"])
    let state = vm.directory.appendingPathComponent("snapshots/" + snapshot + "/state")
    let valid = state.appendingPathExtension("valid")
    try FileManager.default.moveItem(at: state, to: valid)
    try Data("invalid-state".utf8).write(to: state)
    do {
      try await vm.restore(snapshot)
      throw HostError("test_failed", "Corrupt snapshot accepted")
    } catch let error as HostError where error.code == "vm_restore_failed" {
      try check(error.details["diskRestored"] == true, "failed restore reports disk rollback")
    }
    try check(!vm.running, "failed memory restore never silently cold boots")
    let latest = try await vm.execute("fs.read", args: ["path": "snapshot.txt"])
    try check(latest["text"] == "latest", "failed memory restore preserves the latest disk")
    try await vm.stop()
    try FileManager.default.removeItem(at: state)
    try FileManager.default.moveItem(at: valid, to: state)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--restore-only", vm.directory.path, snapshot]
    try process.run()
    let timeout = Task { @MainActor in
      try await Task.sleep(for: .seconds(60))
      if process.isRunning { process.terminate() }
    }
    await Task.detached { process.waitUntilExit() }.value
    timeout.cancel()
    try check(
      process.terminationStatus == 0,
      "new host process restores heap and disk from the same checkpoint")
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
