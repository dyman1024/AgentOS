#!/usr/bin/env python3
"""S4: four application types, ten independent generations each. Default is a free dry run."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

TASKS = {
    "notes": "创建一个笔记应用。支持新增、编辑、删除、全文检索和标签筛选，使用共享 notes 集合。界面有空状态、错误状态、编辑器；每个工具有契约测试，测试含版本冲突。提交可运行版本。",
    "tasks": "创建一个待办应用。支持新增、修改、完成、删除、按截止时间排序，使用共享 tasks 集合。支持筛选未完成任务；每个工具有契约测试，测试含不存在的 ID。提交可运行版本。",
    "bookmarks": "创建一个书签应用。支持按 URL 保存、标签、检索、删除和防止 URL 重复，使用共享 bookmarks 集合。不要访问真实网络；每个工具有契约测试。提交可运行版本。",
    "expenses": "创建一个记账应用。注册用户 expenses 集合，支持收入支出、分类、按月查询、汇总和删除。金额校验非负，收支类型分别记录；每个工具有契约测试。提交可运行版本。",
}
CONTRACT = """验收接口约定（UI 也调用这些接口）：create({id,record})；get({id}) 返回共享记录对象；update({id,record,expectedRev}) 用完整 record 更新；delete({id,expectedRev})；list({text?,tag?,done?,month?,orderBy?}) 返回共享记录对象数组，_id 必须保留。notes 使用 title/body/tags；tasks 使用 title/done/due；bookmarks 使用 title/url/tags 且同 URL 去重；expenses 注册同名集合，字段 title/amount/type(income|expense)/category/date(YYYY-MM-DD)，amount>=0，并实现 totals({month:YYYY-MM})->{income,expense,balance}。只实现与本应用有关的筛选。"""
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--run", action="store_true", help="Authorize paid model requests using the configured account")
parser.add_argument("--budget-usd", type=float, default=0, help="Total run budget; execution stops before reserving beyond it")
parser.add_argument("--case-budget-usd", type=float, default=2)
parser.add_argument("--repetitions", type=int, default=10)
parser.add_argument("--output", default="evals/results/generation.json")
args = parser.parse_args()
if not args.run:
    print(json.dumps({"status": "not_run", "cases": len(TASKS) * args.repetitions, "requires": "configured model key and explicit --run --budget-usd", "thresholds": {"firstPass": 0.8, "interfaceCoverage": 0.9}}, indent=2))
    raise SystemExit(0)
if args.budget_usd <= 0 or not 0.01 <= args.case_budget_usd <= 50 or args.repetitions < 1:
    parser.error("Explicit positive total budget, case budget $0.01–50, and repetitions are required")
repo = Path(__file__).resolve().parent.parent
host = repo / "build/Build/Products/Debug/AgentOS.app/Contents/MacOS/AgentOS"
results = []
spent = 0.0
output = Path(args.output).resolve()
output.parent.mkdir(parents=True, exist_ok=True)

def save():
    expected = len(TASKS) * args.repetitions
    complete = len(results) == expected
    passed = sum(item.get("firstCommitPassed", False) for item in results) / expected
    coverage = sum(item.get("interfaceCoverage", 0) for item in results) / expected
    output.write_text(json.dumps({"status": "complete" if complete else "incomplete", "pass": complete and passed >= .8 and coverage >= .9,
        "costUsd": spent, "expectedCases": expected, "firstPassRate": passed, "interfaceCoverage": coverage, "cases": results}, ensure_ascii=False, indent=2) + "\n")

def run_case(prompt, kind):
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
                client.sendall(json.dumps({"token": endpoint["token"], "method": "evaluation.run", "args": {"task": prompt, "kind": kind, "budgetUSD": args.case_budget_usd}}).encode() + b"\n")
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

for kind, prompt in TASKS.items():
    for repetition in range(args.repetitions):
        if spent + args.case_budget_usd > args.budget_usd + 1e-9:
            save()
            raise SystemExit("Stopped at the total budget; incomplete cases are not counted as passed")
        try:
            result = run_case(prompt + "\n" + CONTRACT, kind)
            spent += result.get("costUsd") if isinstance(result.get("costUsd"), (int, float)) else args.case_budget_usd
            results.append(dict(result, kind=kind, repetition=repetition + 1))
            save()
            print(kind, repetition + 1, "activated=" + str(result.get("activated")), flush=True)
        except Exception as error:
            spent += args.case_budget_usd
            results.append({"kind": kind, "repetition": repetition + 1, "error": str(error), "costUnknown": True})
            save()
            raise
save()
