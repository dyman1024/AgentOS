#!/usr/bin/env python3
"""Validate hardened ad-hoc binaries without any model request or account access."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
app = repo / 'build-release/Build/Products/Release/AgentOS.app'
engine = app / 'Contents/Resources/engine'
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
with tempfile.TemporaryDirectory(prefix='agentos-release-engine-') as directory:
    env={'PATH':'/usr/bin:/bin','HOME':directory,'CLAUDE_CONFIG_DIR':directory,'DISABLE_AUTOUPDATER':'1'}
    child=subprocess.Popen([str(engine/'agentos-engine')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env,text=True)
    try:
        child.stdin.write(json.dumps({'jsonrpc':'2.0','id':1,'method':'verification.unknown'})+'\n');child.stdin.flush()
        selector=selectors.DefaultSelector();selector.register(child.stdout,selectors.EVENT_READ)
        try:
            if not selector.select(timeout=15): raise RuntimeError('Hardened engine did not respond')
            response=json.loads(child.stdout.readline())
            assert response.get('id')==1 and response.get('error',{}).get('code')==-32601,response
        finally:selector.close()
        child.stdin.close();child.wait(timeout=10)
        assert child.returncode==0,child.returncode
    finally:
        if child.poll() is None:child.kill();child.wait()
    result=subprocess.run([str(engine/'claude'),'--version'],env=env,capture_output=True,text=True,timeout=30,check=True)
    assert result.stdout.strip(),'Claude binary did not report its version'
print('PASS: strict bundle signing, hardened Bun JSON-RPC, clean EOF shutdown and Claude binary startup; no model calls')
