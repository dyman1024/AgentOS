#!/usr/bin/env python3
"""Prepare joint migration and custom-shell fixtures in the disposable desktop host."""
import json
from pathlib import Path
import runpy

base = runpy.run_path(str(Path(__file__).with_name("prepare-desktop-fixtures.py")))
call, write, tool, root = (base[k] for k in ("call", "write", "tool", "root"))
old_schema = {"type": "object", "properties": {"amount": {"type": "number"}}, "required": ["amount"], "additionalProperties": False}
new_schema = {"type": "object", "properties": {"total": {"type": "number"}}, "required": ["total"], "additionalProperties": False}
call("data.registerSchema", {"collection": "jointrecords", "type": "jointrecord", "definition": old_schema})
apps = []
for title, namespace in [("联合账本", "jointledger"), ("联合报表", "jointreport")]:
    app = call("apps.create", {"title": title, "namespace": namespace})
    apps.append(app)
    write(app, "interface/interface.json", {"schema": "agentos.interface/1", "id": namespace, "version": "1.0.0",
        "tools": [tool("write")], "data": [{"collection": "jointrecords", "access": "rw"}]})
    write(app, "core.js", "agentos.tools.register('write',()=>agentos.data.collection('jointrecords').put({amount:7}));")
    write(app, "tests/contract.json", [{"name": "old schema", "tool": "write", "args": {}, "expect": {"amount": 7}}])
    call("apps.commit", {"app": app["id"]})
    manifest = dict(app["manifest"], version="1.0.0+2")
    if len(apps) == 1:
        manifest["update"] = {"dataSchema": {"plan": "migration.json"}}
        write(app, "migration.json", {"schema": "agentos.migration/1", "collection": "jointrecords", "fromVersion": 1,
            "toVersion": 2, "definition": new_schema, "steps": [{"op": "rename", "from": "amount", "to": "total"}]})
    write(app, "manifest.json", manifest)
    write(app, "core.js", "agentos.tools.register('write',()=>agentos.data.collection('jointrecords').put({total:7}));")
    write(app, "tests/contract.json", [{"name": "new schema", "tool": "write", "args": {}, "expect": {"total": 7}}])
call("data.put", {"collection": "jointrecords", "id": "existing", "record": {"amount": 42}})
shell = call("apps.create", {"title": "验收桌面", "namespace": "fixtureshell"})
write(shell, "interface/interface.json", {"schema": "agentos.interface/1", "id": "fixtureshell", "version": "1.0.0", "tools": [tool("ping")]})
write(shell, "core.js", "agentos.tools.register('ping',()=>({ok:true}));")
write(shell, "tests/contract.json", [{"name": "ping", "tool": "ping", "args": {}, "expect": {"ok": True}}])
write(shell, "ui/index.html", '''<!doctype html><meta charset="utf-8"><style>body{background:#08080a;color:#f2efe9;font:18px system-ui;padding:32px}button{margin:12px;padding:14px}</style>
<h1>验收桌面</h1><p>手写隔离夹具，不调用模型</p><button id="list">列出应用</button><button id="hang">模拟桌面无响应</button><div id="apps"></div><p id="status"></p>
<script>
agentos.expose(()=>({healthy:true}));
document.querySelector('#list').onclick=async()=>{try{const apps=await agentos.service('shell.apps',{}); document.querySelector('#apps').replaceChildren(...apps.map(app=>{const button=document.createElement('button');button.textContent=app.title;button.onclick=()=>agentos.service('shell.open',{app:app.id});return button;}));document.querySelector('#status').textContent='应用已列出';}catch(e){document.querySelector('#status').textContent=String(e);}};
document.querySelector('#hang').onclick=()=>{document.querySelector('#status').textContent='正在模拟无响应，等待宿主健康检查';agentos.expose(()=>new Promise(()=>{}));};
</script>''')
call("apps.commit", {"app": shell["id"]})
info = dict(base["info"], jointApps=[app["id"] for app in apps], shell=shell["id"])
(root / "evolution-fixtures.json").write_text(json.dumps(info, indent=2))
print(json.dumps(info, indent=2))
print("READY: two staged consumers and one validated custom shell; joint activation requires UI confirmation")
