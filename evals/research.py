#!/usr/bin/env python3
"""S6: twenty research/organization tasks using fixture content and real model calls. Default is a free dry run."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--run", action="store_true", help="Authorize paid model requests using the configured account")
parser.add_argument("--budget-usd", type=float, default=0, help="Total run budget; execution stops before reserving beyond it")
parser.add_argument("--case-budget-usd", type=float, default=2)
parser.add_argument("--output", default="evals/results/research.json")
args = parser.parse_args()
if not args.run:
    print(json.dumps({"status": "not_run", "cases": 20, "requires": "configured model key and explicit --run --budget-usd", "thresholds": {"meanConfirmationsBelow": 1, "allDocumentsSaved": True}, "content": "local fixtures, real kernel policy"}, indent=2))
    raise SystemExit(0)
if args.budget_usd <= 0 or not 0.01 <= args.case_budget_usd <= 50:
    parser.error("Explicit positive total budget, case budget $0.01–50 are required")
repo = Path(__file__).resolve().parent.parent
host = repo / "build/Build/Products/Debug/AgentOS.app/Contents/MacOS/AgentOS"
results = []
spent = 0.0
output = Path(args.output).resolve()
output.parent.mkdir(parents=True, exist_ok=True)

def save():
    expected = 20
    complete = len(results) == expected
    confirmations = sum(item.get("confirmations", 0) for item in results) / expected
    passed = complete and confirmations < 1 and all(item.get("documentSaved") and item.get("sourceRetained") and not item.get("isError") and not item.get("blockedServiceCalls") for item in results)
    output.write_text(json.dumps({"status": "complete" if complete else "incomplete", "pass": passed,
        "meanConfirmations": confirmations, "fixtureContent": True, "realModel": True,
        "costUsd": spent, "expectedCases": expected, "cases": results}, ensure_ascii=False, indent=2) + "\n")

def run_case(index):
    # Every generation gets a fresh host/database/schema registry, including repeated ledger cases.
    with tempfile.TemporaryDirectory(prefix="agentos-eval-") as directory:
        env = dict(os.environ, AGENTOS_DATA_ROOT=directory, AGENTOS_EVAL="1")
        with open(Path(directory) / "host.log", "wb") as log:
            process = subprocess.Popen([str(host), "--background"], env=env, stdout=log, stderr=log)
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(2100)
            try:
                session = Path(directory) / "system/aos-session.json"
                deadline = time.monotonic() + 30
                while not session.exists() and time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError("Evaluation host stopped")
                    time.sleep(.1)
                endpoint = json.loads(session.read_text())
                time.sleep(.3)
                client.connect(endpoint["socket"])
                client.sendall(json.dumps({"token": endpoint["token"], "method": "evaluation.research", "args": {"case": index, "budgetUSD": args.case_budget_usd}}).encode() + b"\n")
                data = bytearray()
                while b"\n" not in data:
                    chunk = client.recv(65536)
                    if not chunk or len(data) + len(chunk) > 8_000_000:
                        raise RuntimeError("Invalid evaluation response")
                    data.extend(chunk)
                response = json.loads(data)
                if "error" in response:
                    raise RuntimeError(response["error"]["message"])
                return response["result"]
            finally:
                client.close()
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()

for index in range(20):
    if spent + args.case_budget_usd > args.budget_usd + 1e-9:
        save()
        raise SystemExit("Stopped at the total budget; incomplete tasks are not counted as passed")
    try:
        result = run_case(index)
        spent += result.get("costUsd") if isinstance(result.get("costUsd"), (int, float)) else args.case_budget_usd
        results.append(result)
        save()
        print(index + 1, "documentSaved=" + str(result.get("documentSaved")), flush=True)
    except Exception as error:
        spent += args.case_budget_usd
        results.append({"case": index, "error": str(error), "costUnknown": True})
        save()
        raise
save()
