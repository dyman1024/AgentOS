#!/usr/bin/env python3
"""Exercise actual local host services in disposable storage without models/accounts."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parent.parent
bundle = repo / "build/Build/Products/Debug/AgentOS.app/Contents"
with tempfile.TemporaryDirectory(prefix="agentos-local-check-") as directory:
    root = Path(directory)
    env = dict(os.environ, AGENTOS_DATA_ROOT=directory, AGENTOS_LOCAL_CHECKS="1")
    with open(root / "host.log", "wb") as log:
        def start():
            process = subprocess.Popen([str(bundle / "MacOS/AgentOS")], env=env, stdout=log, stderr=log)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("Isolated host exited")
                try:
                    state = call("validation.state", timeout=2)
                    return process, state
                except (RuntimeError, subprocess.TimeoutExpired):
                    time.sleep(.1)
            process.terminate()
            process.wait(timeout=10)
            raise RuntimeError("Isolated host did not start")

        def call(method, timeout=60):
            result = subprocess.run([str(bundle / "Resources/engine/aos"), "system", "call",
                "--method", method, "--args", "{}"], env=env,
                capture_output=True, text=True, timeout=timeout)
            if result.returncode:
                raise RuntimeError(result.stderr)
            return json.loads(result.stdout)

        def stop(process):
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

        host = None
        try:
            host, state = start()
            assert state["safeMode"] is False, state
            report = call("validation.local")
            assert report["pass"] and report["modelCalls"] == 0, report
            stop(host)
            host, state = start()
            assert state["safeMode"] is False, state
            stop(host)
            host, state = start()
            assert state["safeMode"] is True, state
            report["checks"].append("two actual unclean host exits enter recovery mode on restart")
            print(json.dumps(report, ensure_ascii=False, indent=2))
        finally:
            if host is not None and host.poll() is None:
                stop(host)
