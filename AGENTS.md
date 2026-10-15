# AGENTS.md

给参与本仓库的 AI Agent（Claude Code、Codex 等）的工作约定。人类协作者也适用。

## 沟通

- **全程用中文回复**，包括过程中的进度说明、提问和最终总结。代码、命令、标识符保持原文。
- 提交说明和 PR 标题沿用英文的 conventional commits 格式（`feat:`、`fix:`、`docs:`……）；PR 描述用中文。

## 项目是什么

Personal AgentOS：macOS 上的**生成式个人操作系统**。电脑在应用层能做的事它都能做，但应用不是预装的，而是用户和 Agent 在使用中生成、迭代出来的；每个应用天生支持同一套协议，可以互相调用和订阅；Agent 拥有照料它们的全部权限。它不是「生成小应用的工具」，新功能优先补平台能力（内核、数据层、权限、系统服务），并用具体场景纵向打通。

产品约束（已定）：只做 macOS；不上 Mac App Store；用户自带 API Key（Anthropic 直连或 OpenRouter）。

## 文档

| 位置 | 用途 | 规则 |
|---|---|---|
| `docs/architecture/` | **正式技术方案**：总览加 00–11 分册 | 开发以此为准。改设计时同步更新对应分册，并在总览的决策记录里补一条 |
| `docs/research/` | 调研记录、方案对比、实验代码 | 决策依据，按时间留存，已有文件不再修改；新调研新建文件 |
| `docs/vision/` | 产品愿景 | 方向性文字，细节以技术方案为准 |
| `docs/design/` | 交互设计稿（也是 GitHub Pages 上的概念介绍页） | 改页面后按 `docs/design/README.md` 重新生成 `cover.png` |

写文档的风格：中文、短句、多用表格；先给结论再给理由；外部事实注明来源，没核实的标「未核实」，本机测得的标「实测」。

## 代码

| 路径 | 内容 |
|---|---|
| `App/` | Swift 6 宿主（SwiftUI + AppKit），默认 MainActor 隔离 |
| `agent-engine/` | Agent 引擎（TypeScript，Claude Agent SDK，Bun 编译成 sidecar） |
| `tests/fixtures/` | 运行时自测和沙箱回归用例 |
| `project.yml` | XcodeGen 工程定义（`.xcodeproj` 不入库） |

常用命令：`make run`（生成工程、编译、打开）、`make build`、`make selftest`（不调用模型的运行时自测）、`make sandbox-test`（沙箱回归用例）、`make engine-check`（引擎类型检查）。引擎开发时可用 `AGENTOS_ENGINE_CMD="bun run $PWD/agent-engine/src/index.ts"` 免重编宿主。更多开关见 `docs/architecture/11-engineering.md`。

## 协作

- 新功能在 `feat/*` 分支，文档在 `docs/*` 分支，通过 PR 合入 `main`。
- 公开仓库：提交前确认没有 API Key、本机绝对路径等敏感信息。
- 改动运行时沙箱（scheme handler、CSP、导航策略、消息桥、注入脚本）时，必须跑 `make sandbox-test` 并全部通过。自测和沙箱用例会把 AgentOS 窗口弹到前台，运行期间不要遮住它。
