# 模型质量评测

所有入口默认免费 dry run，只检查配置/案例数量并输出 `not_run`。实际执行需显式 `--run --budget-usd` 与自己的模型凭据。预算耗尽或不足以预留下一案例时记录 incomplete，绝不把少跑的案例算作通过。

| 套件 | 命令入口 | 通过标准 |
|---|---|---|
| S3 工具选择 | `cd agent-engine && bun run src/evalToolSelection.ts` | 50/100/200 工具，各两策略 ×10；准确率、费用、时延可比较 |
| S4 应用生成 | `python3 evals/generation.py` | 笔记/待办/书签/记账各 10 次；首次提交通过≥80%、独立接口任务覆盖≥90% |
| S6 研究整理 | `python3 evals/research.py` | 20 个任务全部保存文档与来源；平均确认<1；无越权服务调用 |

实跑示例（总额由操作者明确选择）：

```bash
python3 evals/generation.py --run --budget-usd "$AGENTOS_EVAL_BUDGET" --case-budget-usd 2
python3 evals/research.py --run --budget-usd "$AGENTOS_EVAL_BUDGET" --case-budget-usd 2
```

S4/S6 先 `make build`，从设置或本地环境读取模型凭据。每个案例启动独立宿主及 `agentos-eval-*` 数据根，结束后清理，不碰真实用户数据库。S3 使用 Anthropic Key、独立 SDK 配置目录；可用 `--model` 指定模型，默认沿用 Opus 5.5。

S4 明确规定验收工具签名，再独立调用 create/get/update/delete/list；分别验证标签、完成状态、排序、URL 去重、月份汇总和金额约束。记录工具执行结果和实际数据状态。Builder 自带契约用于激活判断，不代替独立接口覆盖率。

S3 只有实际出现 SDK Tool Search 行为时才将该策略列为可比较；代理或 SDK 不支持按需发现时记录不可比较。依据 [SDK Tool Search 官方文档](https://code.claude.com/docs/en/agent-sdk/tool-search)。

S6 使用固定本地网页素材和真实模型/内核/出口策略；无真实发信或发布。该套件测确认频率、来源保留、任务完成与越权尝试，不代替真实网页正确性或文章质量的人类评审。

结果写入 `evals/results/`。结果可能包含模型内容和错误信息，发布前检查隐私。当前仅执行 dry run，尚无真实模型质量结论；费用授权问题仍待答复。
