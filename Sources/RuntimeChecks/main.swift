import AgentOSCore
import AgentOSRuntime
import AppKit
import Foundation

@main struct Checks {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
      do {
        try await run()
        print("PASS: runtime integration")
        exit(0)
      } catch {
        fputs("FAIL: \(error)\n", stderr)
        exit(1)
      }
    }
    app.run()
  }
  @MainActor static func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw HostError("test_failed", message) }
    print("✓ \(message)")
  }
  static func tool(
    _ name: String, input: Value = ["type": "object"], output: Value = ["type": "object"]
  ) -> Value {
    [
      "name": .string(name), "description": .string(name), "input": input, "output": output,
      "examples": [["input": [:]]],
    ]
  }
  @MainActor static func make(
    _ k: Kernel, _ r: RuntimeCoordinator, _ name: String, tools: [Value], data: Value,
    subscribes: Value = [], core: String, tests: Value, ui: String = "<p>Application UI</p>"
  ) async throws -> InstalledApp {
    let app = try await k.createApp(title: name, namespace: name, context: RequestContext(.user))
    let directory = try await k.sourceDirectory(app.id)
    let interface: Value = [
      "schema": "agentos.interface/1", "id": .string(app.namespace), "version": "1.0.0",
      "tools": .array(tools), "data": data, "subscribes": subscribes,
    ]
    try interface.encoded().write(to: directory.appendingPathComponent("interface/interface.json"))
    try Data(core.utf8).write(to: directory.appendingPathComponent("core.js"))
    try Data(ui.utf8).write(to: directory.appendingPathComponent("ui/index.html"))
    try tests.encoded().write(to: directory.appendingPathComponent("tests/contract.json"))
    _ = try await r.commit(app.id, context: RequestContext(.user))
    return try await k.app(app.id)
  }
  @MainActor static func run() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agentos-runtime-" + UUID().uuidString)
    let k = try Kernel(root: root)
    let r = RuntimeCoordinator(kernel: k)
    let user = RequestContext(.user)
    let mail = try await ArticleReader().parseMail(
      "From: sender@example.com\r\nTo: me@example.com\r\nSubject: =?UTF-8?B?5Lit5paH?=\r\nMIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=sample\r\n\r\n--sample\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nExternal message body\r\n--sample\r\nContent-Type: text/html\r\n\r\n<script>throw Error('MIME_SCRIPT_RAN')</script><p>External message body</p>\r\n--sample--\r\n"
    )
    try expect(
      mail["subject"] == "中文" && mail["text"]?.string?.contains("External message body") == true,
      "MIME and Unicode decode in isolated WebContent without executing email scripts")
    let article = try await ArticleReader().extract(
      html:
        "<html><head><title>Isolated article</title></head><body><article><h1>Isolated article</h1><p>"
        + String(repeating: "Verified article text. ", count: 100)
        + "</p><a href='https://example.com/source'>Source</a><script>document.body.textContent='UNTRUSTED_SCRIPT_RAN'</script></article></body></html>",
      url: "https://example.com/article")
    try expect(
      article["text"]?.string?.contains("Verified article text") == true
        && article["text"]?.string?.contains("UNTRUSTED_SCRIPT_RAN") != true,
      "article extraction runs without page scripts or app bridge")
    try expect(
      article["links"]?.array?.first?["url"] == "https://example.com/source",
      "article sources preserved")
    defer {
      r.closeAll()
      try? FileManager.default.removeItem(at: root)
    }
    try await wasm(k, r)
    try await mailAutomation(k, r)
    let notes = try await make(
      k, r, "notes",
      tools: [
        tool(
          "create",
          input: [
            "type": "object", "properties": ["title": ["type": "string"]], "required": ["title"],
          ]), tool("list", output: ["type": "array", "items": ["type": "object"]]),
      ], data: [["collection": "notes", "access": "rw"]],
      core: """
        import {html} from '/_lib/ui.js';
        import {renderMarkdown} from '/_lib/markdown.js';
        if(typeof html !== 'function' || renderMarkdown('<img src=x onerror=alert(1)>').includes('onerror')) throw new Error('UI library isolation failed');
        agentos.tools.register('create', async args => await agentos.data.collection('notes').put(args));
        agentos.tools.register('list', async () => await agentos.data.collection('notes').query());
        """,
      tests: [
        ["name": "initially empty", "tool": "list", "args": [:], "expect": []],
        [
          "name": "create note", "tool": "create", "args": ["title": "Contract note"],
          "expect": ["title": "Contract note"],
        ],
      ],
      ui: """
        <!doctype html><meta charset="utf-8"><h1>Notes UI</h1><script>
        const state={};agentos.expose(()=>state);
        agentos.self.call('create',{title:'UI record'}).then(r=>state.created=r).catch(e=>state.error=String(e));
        agentos.data.collection('notes').put({title:'forbidden'}).then(()=>state.escaped=true).catch(e=>state.denied=e.code);
        </script>
        """)
    try expect(
      try await k.query("notes", context: user).isEmpty, "Contract tests did not mutate user data")
    let tasks = try await make(
      k, r, "tasks", tools: [tool("list", output: ["type": "array", "items": ["type": "object"]])],
      data: [["collection": "tasks", "access": "rw"], ["collection": "notes", "access": "r"]],
      subscribes: [["pattern": "note.created"]],
      core: """
        agentos.tools.register('list',async()=>await agentos.data.collection('tasks').query());
        agentos.events.subscribe('note.created', async ev=>{
          const note=await agentos.data.collection('notes').get(ev.data.id);
          if(!note.title.startsWith('TODO:'))return;
          const tasks=agentos.data.collection('tasks'), id='from-'+note._id;
          try { await tasks.get(id); } catch(e) {if(e.code!=='not_found')throw e;await tasks.put({_id:id,title:note.title.slice(5),source:'note:'+note._id});}
        });
        """, tests: [["name": "list empty", "tool": "list", "expect": []]])
    _ = try await r.instance(tasks.id, core: true)
    let created = try await r.call("notes.create", args: ["title": "TODO: follow up"], caller: user)
    try expect(created["_rev"] == 1, "Hidden core writes through host and returns revision")
    await r.pumpEvents()
    try expect(
      try await k.query("tasks", context: user).count == 1,
      "Closed application receives event and creates one task")
    await r.pumpEvents()
    try expect(
      try await k.query("tasks", context: user).count == 1,
      "Acknowledged event does not create a duplicate task")
    let view = try await r.instance(notes.id, core: false)
    try await Task.sleep(for: .milliseconds(500))
    let state = try await view.invoke(kind: "state", name: "", args: [:])["state"] ?? .null
    try expect(
      state["created"]?["title"] == "UI record", "UI self.call uses the same tool as Agent")
    try expect(state["denied"] == "denied", "UI direct write is rejected by host")
    let base = RequestContext(.core(notes.id), instanceID: r.cores[notes.id]!.instanceID)
    try await k.propagate(Labels(taint: ["test:external"]), to: base)
    r.reload(notes.id)
    let reloaded = try await r.instance(notes.id, core: true)
    try expect(
      try await k.labels(for: RequestContext(.core(notes.id), instanceID: reloaded.instanceID))
        .isUntrusted, "Hot reload preserves taint")
    for grant in try await k.grants().array ?? []
    where grant["holder"]?.string == Principal.core(notes.id).id
      && grant["capability"] == "data.write"
    { try await k.revoke(grant["id"]!.string!) }
    do {
      _ = try await r.call("notes.create", args: ["title": "forbidden"], caller: user)
      throw HostError("test_failed", "Revoked capability was reused")
    } catch let error as HostError {
      try expect(error.code == "denied", "Revocation is enforced in a running core")
    }
    try expect(try await k.verifyAudit(), "Audit chain verifies after runtime calls")
    if let index = CommandLine.arguments.firstIndex(of: "--sandbox"),
      CommandLine.arguments.count > index + 1
    {
      try await sandbox(k, r, fixtures: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    }
    r.closeAll()
    try await k.shutdown()
  }
  @MainActor static func mailAutomation(_ kernel: Kernel, _ runtime: RuntimeCoordinator)
    async throws
  {
    runtime.confirm = { _, _ in true }  // Explicit fixture-only host consent; no real account is connected.
    defer { runtime.confirm = nil }
    let app = try await make(
      kernel, runtime, "mailreview", tools: [tool("review")],
      data: [["collection": "mail", "access": "r"], ["collection": "tasks", "access": "rw"]],
      core: """
        agentos.tools.register('review', async a => {
          if (!a.mailID) return {fixture:true};
          const mail = await agentos.data.collection('mail').get(a.mailID);
          const tasks = agentos.data.collection('tasks'); const id = 'mail-' + mail._id;
          try { return await tasks.get(id); } catch(e) { if(e.code !== 'not_found') throw e; }
          return tasks.put({_id:id,title:'Review '+mail.subject,source:'mail:'+mail._id});
        });
        """, tests: [["name": "fixture", "tool": "review", "expect": ["fixture": true]]])
    let automation = try await kernel.createAutomation(
      [
        "name": "Review incoming mail", "trigger": ["event": "mail.received"],
        "steps": [
          ["tool": .string(app.namespace + ".review"), "args": ["mailID": ["$event": "data.id"]]]
        ],
      ], context: RequestContext(.user))
    let parsed: Value = [
      "subject": "Fixture message", "text": "External instruction-like content stays data",
    ]
    _ = try await kernel.indexMail(
      account: "fixture", folder: "INBOX", validity: 1, uid: 7, parsed: parsed)
    await runtime.pumpAutomations()
    for _ in 0..<100 where runtime.hasActiveWork { try await Task.sleep(for: .milliseconds(20)) }
    let records = try await kernel.query(
      "tasks", where: ["title": "Review Fixture message"], context: RequestContext(.user))
    try expect(
      records.count == 1 && records[0].labels.isPrivate && records[0].labels.isUntrusted,
      "external mail event runs a fixed tool plan without UI and preserves privacy/source labels")
    let duplicate = try await kernel.indexMail(
      account: "fixture", folder: "INBOX", validity: 1, uid: 7, parsed: parsed)
    await runtime.pumpAutomations()
    let afterDuplicate = try await kernel.query(
      "tasks", where: ["title": "Review Fixture message"], context: RequestContext(.user))
    try expect(
      !duplicate && afterDuplicate.count == 1,
      "mail re-sync does not duplicate automation effects")
    try await kernel.setAutomation(automation, enabled: false, context: RequestContext(.user))
    // Leave the shared task fixture empty for the independent notes-to-tasks scenario.
    _ = try await kernel.delete(
      "tasks", id: records[0].id, expectedRevision: records[0].rev, context: RequestContext(.user))
  }
  @MainActor static func wasm(_ kernel: Kernel, _ runtime: RuntimeCoordinator) async throws {
    let user = RequestContext(.user)
    let app = try await kernel.createApp(
      title: "WASM compute", namespace: "wasmcheck", context: user)
    let directory = try await kernel.sourceDirectory(app.id)
    var manifest = app.manifest.object!
    manifest["runtime"] = [
      "kind": "wasm-component", "module": "add.wasm", "core": "core.js", "ui": "ui/index.html",
    ]
    try Value.object(manifest).encoded().write(
      to: directory.appendingPathComponent("manifest.json"))
    try Data([
      0, 97, 115, 109, 1, 0, 0, 0, 1, 7, 1, 96, 2, 127, 127, 1, 127, 3, 2, 1, 0, 7, 7, 1, 3, 97,
      100, 100, 0, 0, 10, 9, 1, 7, 0, 32, 0, 32, 1, 106, 11,
    ]).write(to: directory.appendingPathComponent("add.wasm"))
    let definition: Value = [
      "schema": "agentos.interface/1", "id": "wasmcheck", "version": "1.0.0",
      "tools": [tool("add", output: ["type": "number"])],
    ]
    try definition.encoded().write(to: directory.appendingPathComponent("interface/interface.json"))
    try Data(
      "const wasm=await agentos.wasm.load('/add.wasm');agentos.tools.register('add',a=>wasm.add(a.a||0,a.b||0));"
        .utf8
    ).write(to: directory.appendingPathComponent("core.js"))
    let tests: Value = [
      ["name": "integer addition", "tool": "add", "args": ["a": 20, "b": 22], "expect": 42]
    ]
    try tests.encoded().write(to: directory.appendingPathComponent("tests/contract.json"))
    _ = try await runtime.commit(app.id, context: user)
    try expect(
      try await runtime.call("wasmcheck.add", args: ["a": 7, "b": 8], caller: user) == 15,
      "WASM asset passes isolated contracts and executes in the hidden core")
  }
  @MainActor static func sandbox(_ k: Kernel, _ r: RuntimeCoordinator, fixtures: URL) async throws {
    let neighbor = try await k.createApp(
      title: "Neighbor", namespace: "neighbor", context: RequestContext(.user))
    let neighborDir = try await k.sourceDirectory(neighbor.id)
    try Data("window.__neighborSecret=true".utf8).write(
      to: neighborDir.appendingPathComponent("secret.js"))
    let names = [
      "sandbox-escape.html", "sandbox-probe1-egress-and-isolation.html",
      "sandbox-probe2-iframe-traversal.html", "sandbox-probe3-toplevel-traversal.html",
    ]
    for (index, name) in names.enumerated() {
      let app = try await k.createApp(
        title: name, namespace: "probe\(index)", context: RequestContext(.user))
      let dir = try await k.sourceDirectory(app.id)
      // Use a JavaScript control: the rebuilt runtime correctly enforces nosniff for HTML.
      let html = try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
        .replacingOccurrences(
          of: "r.ownScript = await scriptProbe(`agentos://${r.appId}/index.html`);",
          with: "r.ownScript = await scriptProbe(`agentos://${r.appId}/control.js`);")
      try Data(html.utf8).write(to: dir.appendingPathComponent("ui/index.html"))
      try Value.object(["neighborId": .string(neighbor.id)]).encoded().write(
        to: dir.appendingPathComponent("ui/selftest-context.json"))
      try Data("window.ownScriptLoaded=true".utf8).write(
        to: dir.appendingPathComponent("control.js"))
      // The fixture itself is not an installable application; bind it directly to the same sandbox implementation.
      let instance = try await WebInstance(app: app, directory: dir, isCore: false, temporary: true)
      defer { instance.close() }
      let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 960, height: 680),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.contentView = instance.webView
      window.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
      defer { window.orderOut(nil) }
      try await instance.ready()
      try await Task.sleep(for: .seconds(index == 3 ? 8 : 6))
      let state = try await instance.invoke(kind: "state", name: "", args: [:])["state"] ?? .null
      print("Sandbox state \(name): \(try state.text())")
      if index == 0 {
        for key in ["fetch", "cdnImport", "ws"] {
          try expect(state[key]?.string?.hasPrefix("blocked") == true, "\(name) \(key)")
        }
      }
      if index == 1 {
        try expect(state["done"] == true && state["hasNeighbor"] == true, "probe1 finished")
        try expect(state["ownScript"] == "load", "own files remain readable")
        for key in ["neighborFetch", "traversalFetch"] {
          try expect(state[key] != nil && state[key]?["ok"] != true, "\(key) rejected")
        }
        for key in ["neighborScript", "unregisteredScript", "traversalScriptExisting"] {
          try expect(state[key] == "error", "\(key) rejected")
        }
        for key in [
          "neighborSecretLeaked", "rtcAvailable", "iframeRtcAvailable", "blankIframeRtcAvailable",
          "hooksVisible", "hooksWritable",
        ] { try expect(state[key] == false, "\(key) false") }
        try expect(state["iframeSameOrigin"] == true, "same-origin iframe exercised")
      }
      if index == 2 {
        try expect(
          state["done"] == true && state["reader"] == nil && state["rtcAvailable"] == false,
          "iframe traversal and RTC blocked")
      }
      if index == 3 {
        try expect(
          state["done"] == true && state["hasNeighbor"] == true && state["broughtBack"] == nil,
          "top-level probe completed without reads")
        for key in ["traversal", "neighbor", "dataUrl"] {
          try expect(state["attempts"]?[key] == "blocked", "navigation \(key) blocked")
        }
      }
    }
  }
}
