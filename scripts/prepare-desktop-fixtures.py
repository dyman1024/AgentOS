#!/usr/bin/env python3
"""Start an isolated, disposable desktop session without calling a model or external service.

Uses the real host CLI, package validation, contract runner and event bus. The two
apps are hand-written test fixtures, not evidence of model generation quality.
Quit the running AgentOS first. Close this session with Command-Q when finished.
The printed temporary directory remains available for verification and removal.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parent.parent
bundle = repo / "build/Build/Products/Debug/AgentOS.app/Contents"
root = Path(tempfile.mkdtemp(prefix="agentos-desktop-check-"))
env = dict(os.environ, AGENTOS_DATA_ROOT=str(root))
log = open(root / "host.log", "wb")
host = subprocess.Popen([str(bundle / "MacOS/AgentOS")], env=env, stdout=log,
                        stderr=log, start_new_session=True)
log.close()


def call(method, args=None):
    result = subprocess.run(
        [str(bundle / "Resources/engine/aos"), "system", "call", "--method", method,
         "--args", json.dumps(args or {}, ensure_ascii=False)],
        env=env, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout)


def write(app, path, content):
    call("workspace.write", {"app": app["id"], "path": path,
                            "content": content if isinstance(content, str)
                            else json.dumps(content, ensure_ascii=False)})


def tool(name, input=None, output=None):
    return {"name": name, "description": "桌面验收夹具：" + name,
            "input": input or {"type": "object"},
            "output": output or {"type": "object"}, "examples": [{"input": {}}]}


def page(title, editable=False):
    form = ('<form id="editor"><label>笔记标题<input id="title" required></label>'
            '<label>正文<textarea id="body"></textarea></label>'
            '<button type="submit">保存笔记</button></form>') if editable else ""
    submit = """
document.querySelector('#editor').onsubmit = async e => {
  e.preventDefault();
  try {
    await agentos.self.call('create', {title: document.querySelector('#title').value,
      body: document.querySelector('#body').value});
    document.querySelector('#editor').reset();
    document.querySelector('#status').textContent = '笔记已保存';
    await refresh();
  } catch (error) { document.querySelector('#status').textContent = String(error); }
};
""" if editable else ""
    return """<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<style>
:root{color-scheme:dark}body{margin:32px;font:15px system-ui;background:#08080a;color:#f2efe9}
h1{font-size:28px}p{color:#aaa}label{display:block;margin:16px 0}
input,textarea{display:block;width:90%;padding:12px;margin-top:8px;border:1px solid #555;border-radius:8px}
button{padding:10px 18px;background:#ff5b2e;border:0;border-radius:8px;color:#08080a}
li{padding:12px;border-bottom:1px solid #333;white-space:pre-wrap}#status{color:#6ef2c2}
</style><h1>""" + title + """</h1>
<p>手写桌面验收夹具 · 临时数据 · 不调用模型</p>""" + form + """
<p id="status" role="status"></p><ul id="records"></ul>
<script>
async function refresh() {
  try {
    const records = await agentos.self.call('list', {});
    document.querySelector('#records').replaceChildren(...records.map(record => {
      const item = document.createElement('li');
      item.textContent = record.title + (record.body ? '\\n' + record.body : '');
      return item;
    }));
  } catch (error) { document.querySelector('#status').textContent = String(error); }
}
""" + submit + """
refresh(); setInterval(refresh, 2000);
</script></html>"""


try:
    deadline = time.monotonic() + 45
    while True:
        if host.poll() is not None:
            raise RuntimeError("Host exited; inspect " + str(root / "host.log"))
        try:
            assert call("apps.list") == [], "Expected an empty temporary root"
            break
        except RuntimeError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.2)

    notes = call("apps.create", {"title": "验收笔记", "namespace": "desktopnotes"})
    notes_interface = {
        "schema": "agentos.interface/1", "id": notes["namespace"], "version": "1.0.0",
        "tools": [
            tool("create", {"type": "object", "properties": {
                "title": {"type": "string"}, "body": {"type": "string"}},
                "required": ["title"]}),
            tool("list", output={"type": "array", "items": {"type": "object"}})],
        "data": [{"collection": "notes", "access": "rw"}]}
    contracts = [
        {"name": "isolated empty data", "tool": "list", "args": {}, "expect": []},
        {"name": "write through core", "tool": "create", "args": {"title": "Contract only"},
         "expect": {"title": "Contract only"}}]
    write(notes, "interface/interface.json", notes_interface)
    write(notes, "core.js", """
agentos.tools.register('create', async args => agentos.data.collection('notes').put(args));
agentos.tools.register('list', async () => agentos.data.collection('notes').query());
""")
    write(notes, "ui/index.html", page("验收笔记 · v1", True))
    write(notes, "tests/contract.json", contracts)
    call("apps.commit", {"app": notes["id"]})
    versions_v1 = call("apps.versions", {"app": notes["id"]})
    notes["manifest"]["version"] = "1.0.0+2"
    write(notes, "manifest.json", notes["manifest"])
    notes_interface["version"] = "1.1.0"
    write(notes, "interface/interface.json", notes_interface)
    write(notes, "tests/contract.json", [
        {"name": "deliberate failure", "tool": "list", "args": {}, "expect": ["impossible"]}])
    try:
        call("apps.commit", {"app": notes["id"]})
        raise AssertionError("Broken contract activated")
    except RuntimeError as error:
        assert "contract" in str(error).lower(), error
    assert call("apps.versions", {"app": notes["id"]}) == versions_v1
    write(notes, "tests/contract.json", contracts)
    write(notes, "ui/index.html", page("验收笔记 · v2", True))
    call("apps.commit", {"app": notes["id"]})
    assert call("data.query", {"collection": "notes"}) == []

    tasks = call("apps.create", {"title": "验收待办", "namespace": "desktoptasks"})
    write(tasks, "interface/interface.json", {
        "schema": "agentos.interface/1", "id": tasks["namespace"], "version": "1.0.0",
        "tools": [tool("list", output={"type": "array", "items": {"type": "object"}})],
        "data": [{"collection": "tasks", "access": "rw"}, {"collection": "notes", "access": "r"}],
        "subscribes": [{"pattern": "note.created"}]})
    write(tasks, "core.js", """
agentos.tools.register('list', async () => agentos.data.collection('tasks').query());
agentos.events.subscribe('note.created', async event => {
  const note = await agentos.data.collection('notes').get(event.data.id);
  if (!note.title.startsWith('TODO:')) return;
  const tasks = agentos.data.collection('tasks'), id = 'from-' + note._id;
  try { await tasks.get(id); } catch (error) {
    if (error.code !== 'not_found') throw error;
    await tasks.put({_id: id, title: note.title.slice(5).trim(), source: 'note:' + note._id});
  }
});
""")
    write(tasks, "ui/index.html", page("验收待办"))
    write(tasks, "tests/contract.json", [
        {"name": "isolated empty data", "tool": "list", "args": {}, "expect": []}])
    call("apps.commit", {"app": tasks["id"]})
    assert call("apps.call", {"tool": "desktoptasks.list", "args": {}}) == []
    info = {"root": str(root), "pid": host.pid, "notes": notes["id"], "tasks": tasks["id"],
            "notes_v1": versions_v1[0], "modelCalls": 0}
    (root / "desktop-fixtures.json").write_text(json.dumps(info, indent=2))
    print(json.dumps(info, indent=2))
    print("PASS: fixture contracts, rejected broken version and unchanged user collections")
except BaseException:
    host.terminate()
    host.wait(timeout=10)
    raise
