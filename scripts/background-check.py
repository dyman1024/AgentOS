#!/usr/bin/env python3
"""Exercise a real foreground/background handoff with disposable data and no accounts."""
import json
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
options = parser.parse_args()
build = "build" if options.configuration == "Debug" else "build-release"
bundle = repo / build / "Build/Products" / options.configuration / "AgentOS.app/Contents"
host = bundle / "MacOS/AgentOS"
cli = bundle / "Resources/engine/aos"

with tempfile.TemporaryDirectory(prefix="agentos-background-check-") as directory:
    root = Path(directory)
    env = dict(os.environ, AGENTOS_DATA_ROOT=directory)
    processes = []
    log = open(root / "host.log", "wb")

    def start(*args):
        process = subprocess.Popen([str(host), *args], env=env, stdout=log, stderr=log)
        processes.append(process)
        return process

    def call(method, args=None):
        result = subprocess.run([str(cli), "system", "call", "--method", method,
                                 "--args", json.dumps(args or {})], env=env,
                                capture_output=True, text=True, timeout=10)
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        return json.loads(result.stdout)

    def wait_role(role):
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            try:
                if (root / "system/host-role").read_text() == role:
                    call("apps.list")
                    return
            except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
                pass
            time.sleep(0.15)
        raise RuntimeError("Host never acquired role: " + role)

    try:
        background = start("--background")
        wait_role("background")
        call("data.put", {"collection": "notes", "id": "handoff", "record": {"title": "交接验证", "body": "持久数据"}})
        foreground = start()
        wait_role("foreground")
        record = call("data.get", {"collection": "notes", "id": "handoff"})
        assert record["body"] == "持久数据", record
        try:
            call("system.releaseBackground")
            raise AssertionError("Foreground accepted a background-only handoff")
        except RuntimeError as error:
            assert "conflict" in str(error), error
        foreground.terminate()
        foreground.wait(timeout=10)
        wait_role("background")
        record = call("data.get", {"collection": "notes", "id": "handoff"})
        assert record["body"] == "持久数据", record
        assert background.poll() is None
        print("PASS: authenticated handoff, one database owner, foreground refusal, background reacquisition and data persistence")
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        log.close()
