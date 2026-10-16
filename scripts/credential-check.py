#!/usr/bin/env python3
"""Verify credential save/read/replacement across real host launches; uses only disposable fixtures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parent.parent
bundle = repo / "build/Build/Products/Debug/AgentOS.app/Contents"
with tempfile.TemporaryDirectory(prefix="agentos-local-check-") as directory:
    env = dict(os.environ, AGENTOS_DATA_ROOT=directory, AGENTOS_LOCAL_CHECKS="1")
    host = None
    with open(Path(directory) / "host.log", "wb") as log:
        def call(phase, method="validation.credentials"):
            result = subprocess.run([str(bundle / "Resources/engine/aos"), "system", "call",
                "--method", method, "--args", json.dumps({"phase": phase})], env=env,
                capture_output=True, text=True, timeout=10)
            if result.returncode:
                raise RuntimeError(result.stderr)
            return json.loads(result.stdout)

        def start():
            global host
            host = subprocess.Popen([str(bundle / "MacOS/AgentOS")], env=env, stdout=log, stderr=log)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if host.poll() is not None:
                    raise RuntimeError("Isolated host exited")
                try:
                    call("", "validation.state")
                    return
                except (RuntimeError, subprocess.TimeoutExpired):
                    time.sleep(.1)
            raise RuntimeError("Isolated host did not start")

        def stop():
            if host is not None and host.poll() is None:
                host.terminate()
                try:
                    host.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    host.kill()
                    host.wait()

        try:
            start()
            assert call("write")["pass"]
            stop()
            start()
            report = call("read")
            assert report["pass"] and report["modelCalls"] == 0
            print("PASS: host saves, reads and replaces provider-isolated credentials; restart retains the current Key; no model calls")
        finally:
            if host is not None and host.poll() is None:
                try:
                    call("cleanup")
                finally:
                    stop()
