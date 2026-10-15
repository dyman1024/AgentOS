# 11 工程体系

> 所属：[技术方案总览](README.md)

## 1. 仓库结构

```
AgentOS/
├── AGENTS.md                # 给 AI Agent 和协作者的工作约定（全程中文、文档规则、常用命令）
├── CLAUDE.md                # 只有一行 @AGENTS.md，让 Claude Code 读到同一份约定
├── App/                     # Swift 宿主（SwiftUI + AppKit）
│   ├── AgentOSApp.swift     # 入口、主窗口、工具栏、菜单命令
│   ├── AppModel.swift       # 根状态：串联对话、引擎和运行时
│   ├── Agent/               # EngineClient：引擎子进程和 JSON-RPC
│   ├── Apps/                # 应用注册表、启动台
│   ├── Chat/                # 对话模型和视图
│   ├── Runtime/             # 界面 WebView、scheme、shim、自测工具、截图分析；P1a 增加核心宿主
│   ├── Settings/            # 服务商、模型、Key（钥匙串、在线校验）、OpenRouter 模型目录
│   ├── Support/             # JSON、目录路径、日志
│   ├── Dev/                 # 开发自动化（自测、自动发送提示）
│   ├── Kernel/              # P1a：主体、授权、运行、副作用记录、检查点、审计（00）
│   ├── Data/                # P1a：数据层（08）
│   ├── Protocol/            # P1a：接口注册表、路由、元工具（05）
│   ├── Bus/                 # P1b：事件总线（06）
│   └── Services/            # P2：系统服务和出口（07）
├── agent-engine/            # Agent 引擎（TypeScript，Claude Agent SDK，Bun 编译）
│   └── src/                 # index.ts、rpc.ts、prompt.ts、runtimeTools.ts、partialJson.ts
├── AppTests/                # P1a：XCTest（内核、数据层、总线、接口校验）
├── scripts/bundle-engine.sh # Xcode 构建阶段：编译引擎，复制 claude 二进制
├── tests/fixtures/          # 运行时自测用例和沙箱回归用例
├── evals/                   # P1a：评测集（提示、期望、评分脚本）
├── Config/AgentOS.xcconfig  # 签名配置（可以 include 一个 Local.xcconfig）
├── project.yml              # XcodeGen 工程定义（.xcodeproj 不入库）
├── Makefile
└── docs/
    ├── architecture/        # 技术方案（总览加 00–11 分册，本文所在目录）
    ├── research/            # 调研记录、评估和实验代码
    ├── vision/              # 愿景
    └── design/              # 交互设计稿
```

## 2. 构建

| 项 | 说明 |
|---|---|
| 环境 | **macOS 26 及以上**（P1a 起；P0 是 15）、Xcode 26、XcodeGen、Bun |
| 工程 | `project.yml` 由 XcodeGen 生成 `AgentOS.xcodeproj`；Swift 6，默认 MainActor 隔离，开启 Approachable Concurrency |
| 依赖 | P1a 起通过 SwiftPM 引入 GRDB.swift（SQLite），在 `project.yml` 的 `packages` 里锁定版本 |
| 引擎打包 | 构建后执行 `scripts/bundle-engine.sh`：用 `bun build --compile` 把引擎打成单文件，再把 `@anthropic-ai/claude-agent-sdk-darwin-arm64/claude` 复制到 `Contents/Resources/engine/`，最后清理 Bun 留下的 `.*.bun-build` 临时文件 |
| 签名 | 默认 ad-hoc；想用自己的证书，就在 `Config/Local.xcconfig`（不入库）里设置 `CODE_SIGN_IDENTITY` 和 `DEVELOPMENT_TEAM`。ad-hoc 签名在每次重新编译后都会变，访问钥匙串时可能需要重新允许 |
| Hardened runtime | 现在是关闭的（`ENABLE_HARDENED_RUNTIME: NO`）。公证要求打开，P1a 通过 S5 验证后打开 |
| 产物体积 | 约 300 MB，其中 claude 二进制约 248 MB，引擎约 65 MB |

常用命令（[Makefile](../../Makefile)）：

| 命令 | 作用 | 阶段 |
|---|---|---|
| `make project` | 生成 Xcode 工程 | P0 |
| `make build` | 编译 | P0 |
| `make run` | 编译并打开 App | P0 |
| `make selftest` | 不调用模型，跑一遍运行时自测 | P0 |
| `make engine-check` | TypeScript 类型检查 | P0 |
| `make sandbox-test` | 跑全部沙箱回归用例，任何一项没被拦截就失败 | P1a |
| `make test` | XCTest 单元测试 | P1a |
| `make eval SUITE=<名字>` | 跑评测集（需要真实 Key，会产生费用） | P1a |
| `make clean` | 清理构建产物 | P0 |

## 3. 开发开关

| 开关 | 作用 |
|---|---|
| `AGENTOS_ENGINE_CMD="bun run $PWD/agent-engine/src/index.ts"` | 直接用源码运行引擎，改完引擎不用重新编译 App |
| `AGENTOS_AUTOPROMPT="做个贪吃蛇"` / `AGENTOS_AUTOQUIT=1` | 启动后自动发送这条提示，完成后截图，然后退出 |
| `--selftest-runtime <file.html>` | 把任意 HTML 当成应用，跑一遍运行时自测，结果写到 `logs/selftest-result.json` |
| `-provider openrouter` / `-provider anthropic` | 本次启动临时切换服务商，不写入设置 |
| `ANTHROPIC_API_KEY` / `OPENROUTER_API_KEY` | 钥匙串里没有 Key 时，用这里的值 |
| `AGENTOS_SELFTEST_KEEP=1` | 自测结束后保留临时应用，方便排查 |
| `AGENTOS_DATA_ROOT=<目录>`（P1a） | 把整个数据根目录换到别处，用于测试和评测，不碰真实数据 |

## 4. 测试与评测

| 层次 | 方式 | 状态 |
|---|---|---|
| 运行时 | `make selftest`：贪吃蛇用例要全部通过（约 60 fps） | ✅ |
| **沙箱回归** | `make sandbox-test`：`sandbox-escape.html`（外网访问）加上三个探针（越界读取、跨应用读取、WebRTC、iframe、测试钩子），全部必须被拦截。探针来源见 [sandbox-probes/](../research/sandbox-probes/) | P1a |
| 引擎 | `make engine-check`；用无效 Key 走完整链路，Anthropic 和 OpenRouter 都必须快速失败（约 8–11 s） | ✅ |
| 单元测试 | XCTest：内核（有效权限、检查点决定、撤销）、数据层（乐观并发、历史、字段级撤销冲突）、总线（至少一次、游标、背压）、接口（schema 校验、兼容性比较、lint） | P1a |
| 契约测试 | 每个应用的 `tests/contract.json`，由运行器在临时数据副本上执行（[05](05-app-protocol.md) 第 13 节） | P1a |
| 端到端 | `AGENTOS_AUTOPROMPT` 自动生成应用，检查截图和日志 | ✅（需要真实 Key） |
| **评测集** | 游戏 10 个；协议应用（笔记、待办、书签、记账本）；Operator 跨应用任务；P2 起加注入用例（[02](02-agent.md) 第 4 节） | P1a 起 |

**评测指标：**

| 指标 | 定义 |
|---|---|
| 一次通过率 | 不经用户干预，冒烟测试和契约测试都通过 |
| 首次可用时间 | 从发出请求到应用可用 |
| 单个应用的成本 | 宿主记账的费用（[00](00-kernel.md) 第 10 节） |
| 修复轮数 | 自测失败后修复的轮数 |
| **接口覆盖率** | 评测脚本列出的界面任务中，只通过接口（`apps.call` / `data.*`）就能完成的比例 |
| 注入拦截率（P2） | 注入用例中，没有出现未经确认的出口调用的比例 |
| 每任务确认次数（P2） | 正常任务平均弹出的确认框数量，目标小于 1 |

## 5. 日志与诊断

| 位置（`~/Library/Application Support/AgentOS/system/`，P0 在上一级目录） | 内容 |
|---|---|
| `logs/agentos-<时间>.jsonl` | 宿主事件，每次启动一个文件：`launched`、`engine_started`、`engine_stderr`、`prompt`、`prompt_result`、`runtime_call`、`smoke_test`、`error`…… |
| `logs/selftest-*.json` / `*.png` | 自测结果和截图 |
| `agent/projects/<cwd>/<session>.jsonl` | Agent SDK 的会话记录，包括 API 错误和重试的详情 |
| `kernel.sqlite` | 运行、副作用记录、审计（P1a 起） |
| `meta/<appId>/` | 对话记录 |

排查问题时，先看 `logs/`，再看 `agent/` 里对应会话的 `api_error`，再按 `runId` 查 `kernel.sqlite`。

## 6. 持续集成（P1a）

- GitHub Actions，`macos-26` runner（公开仓库免费）。
- 每个 PR：`make build`、`make test`、`make engine-check`、`make sandbox-test`。
- `make selftest` 和 `make sandbox-test` 需要窗口可见（WebKit 会暂停不可见的页面）。GitHub 的 macOS runner 有图形会话，预计可以运行，需要在接入时验证；不行就改为在合并前本地运行，并在 PR 模板里勾选。
- 评测集不在 CI 里跑（需要真实 Key、会产生费用），每周或改动 Builder 提示词时手动运行，结果记录到 `evals/results/`。

## 7. 协作流程

- **工作约定**写在根目录的 [AGENTS.md](../../AGENTS.md)：全程中文回复、文档规则、常用命令。
- **分支**：新功能在 `feat/*` 分支开发，文档在 `docs/*` 分支，通过 PR 合入 `main`。
- **提交**：提交说明用英文的 conventional commits 格式（`feat:`、`fix:`、`docs:`……）；由 Claude 参与的提交，结尾带上 `Co-Authored-By` 署名。PR 描述用中文。
- **文档**：`docs/architecture/` 是正式方案，修改设计时同步更新对应分册，并在总览里补一条决策记录；调研和评估记录在 `docs/research/`，已有文件不再修改。
- **仓库**：https://github.com/dyman1024/AgentOS （公开仓库，提交前确认没有 Key、本机路径等敏感信息）。

## 8. 技术验证清单（动工前）

| # | 问题 | 方法 | 通过标准 | 影响 | 前置于 |
|---|---|---|---|---|---|
| S1 | 不在窗口里的 WKWebView 能否可靠地执行 JS | `inactiveSchedulingPolicy = .none`，测定时器、Promise、消息桥、`callAsyncJavaScript` 在不同可见性下的行为，以及每个实例的内存 | 工具调用 p95 延迟小于 200 ms；连续 1 小时不被挂起；每个实例的内存有明确数字 | 核心宿主的实现方式（[03](03-app-runtime.md) 第 4.2 节） | P1a |
| S2 | 运行时加固 | 实现 [03](03-app-runtime.md) 第 5 节的六项措施，跑全部探针 | 三个探针加原有的 `sandbox-escape` 全部被拦截 | 安全底线 | P1a |
| S3 | Agent 面对大量工具的准确率 | 合成 50、100、200 个应用工具，对比「三个元工具」和「SDK 按需加载」 | 选出准确率和成本更好的一种 | 元工具设计（[05](05-app-protocol.md) 第 9 节） | P1b |
| S4 | Builder 能否稳定地交付核心、接口和契约测试 | 按新的生成顺序，让 Builder 生成笔记、待办、书签、记账本各 10 次 | 契约测试一次通过率不低于 80%；接口覆盖率不低于 90% | Builder 提示词和模板（[02](02-agent.md) 第 3.3 节） | P1a 中期 |
| S5 | 分发链路 | 打开 hardened runtime，对引擎和 claude 二进制签名并公证；接入 Sparkle；确认重新签名 claude 二进制符合 SDK 条款 | 公证通过，在一台干净的 Mac 上能启动并调用模型 | 引擎打包方式 | P1a |
| S6 | 确认框频率 | 在会话级污点的定义下，跑 20 个研究和整理类任务 | 每个任务平均确认次数小于 1 | 出口策略（[09](09-security.md) 第 4 节） | P2 |
| S7 | VM 出站控制 | 不给 VM 直通网卡，用宿主侧用户态网络栈执行白名单 | VM 里的进程无法绕过白名单访问外网 | VM 网络设计（[10](10-workbench-vm.md) 第 3 节） | P3 |

## 9. 发布（规划）

- AgentOS 本体：用 Developer ID 签名并公证，用 Sparkle 做自动更新（Ed25519 签名），在官网直接分发。前提是 S5 通过。
- 应用的签名与 AgentOS 本体的签名严格分开（[04](04-app-package.md) 第 9 节）。
