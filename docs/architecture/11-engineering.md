# 11 工程体系

> 所属：[技术方案总览](README.md)

## 1. 仓库结构

```
AgentOS/
├── App/                     # Swift 宿主（SwiftUI + AppKit）
│   ├── AgentOSApp.swift     # 入口、主窗口、工具栏、菜单命令
│   ├── AppModel.swift       # 根状态：串联对话、引擎和运行时
│   ├── Agent/               # EngineClient：引擎子进程和 JSON-RPC
│   ├── Apps/                # 应用注册表、启动台
│   ├── Chat/                # 对话模型和视图
│   ├── Runtime/             # WebView 运行时：scheme、shim、自测工具、截图分析
│   ├── Settings/            # 服务商、模型、Key（钥匙串、在线校验）、OpenRouter 模型目录
│   ├── Support/             # JSON、目录路径、日志
│   └── Dev/                 # 开发自动化（自测、自动发送提示）
├── agent-engine/            # Agent 引擎（TypeScript，Claude Agent SDK，Bun 编译）
│   └── src/                 # index.ts、rpc.ts、prompt.ts、runtimeTools.ts、partialJson.ts
├── scripts/bundle-engine.sh # Xcode 构建阶段：编译引擎，复制 claude 二进制
├── tests/fixtures/          # 运行时自测用例（snake.html、sandbox-escape.html）
├── Config/AgentOS.xcconfig  # 签名配置（可以 include 一个 Local.xcconfig）
├── project.yml              # XcodeGen 工程定义（.xcodeproj 不入库）
├── Makefile
└── docs/
    ├── architecture/        # 技术方案（总览加分册，本文所在目录）
    ├── research/            # 调研记录和实验代码
    └── vision/              # 愿景
```

## 2. 构建

| 项 | 说明 |
|---|---|
| 环境 | macOS 15 及以上（开发机 26.5）、Xcode 26、XcodeGen、Bun |
| 工程 | `project.yml` 由 XcodeGen 生成 `AgentOS.xcodeproj`；Swift 6，默认 MainActor 隔离，开启 Approachable Concurrency |
| 引擎打包 | 构建后执行 `scripts/bundle-engine.sh`：用 `bun build --compile` 把引擎打成单文件，再把 `@anthropic-ai/claude-agent-sdk-darwin-arm64/claude` 复制到 `Contents/Resources/engine/`，最后清理 Bun 留下的 `.*.bun-build` 临时文件 |
| 签名 | 默认 ad-hoc；想用自己的证书，就在 `Config/Local.xcconfig`（不入库）里设置 `CODE_SIGN_IDENTITY` 和 `DEVELOPMENT_TEAM`。ad-hoc 签名在每次重新编译后都会变，访问钥匙串时可能需要重新允许 |
| 产物体积 | 约 300 MB，其中 claude 二进制约 248 MB，引擎约 65 MB |

常用命令（[Makefile](../../Makefile)）：

| 命令 | 作用 |
|---|---|
| `make project` | 生成 Xcode 工程 |
| `make build` | 编译 |
| `make run` | 编译并打开 App |
| `make selftest` | 不调用模型，跑一遍运行时自测 |
| `make engine-check` | TypeScript 类型检查 |
| `make clean` | 清理构建产物 |

## 3. 开发开关

| 开关 | 作用 |
|---|---|
| `AGENTOS_ENGINE_CMD="bun run $PWD/agent-engine/src/index.ts"` | 直接用源码运行引擎，改完引擎不用重新编译 App |
| `AGENTOS_AUTOPROMPT="做个贪吃蛇"` / `AGENTOS_AUTOQUIT=1` | 启动后自动发送这条提示，完成后截图，然后退出 |
| `--selftest-runtime <file.html>` | 把任意 HTML 当成应用，跑一遍运行时自测，结果写到 `logs/selftest-result.json` |
| `-provider openrouter` / `-provider anthropic` | 本次启动临时切换服务商，不写入设置 |
| `ANTHROPIC_API_KEY` / `OPENROUTER_API_KEY` | 钥匙串里没有 Key 时，用这里的值 |
| `AGENTOS_SELFTEST_KEEP=1` | 自测结束后保留临时应用，方便排查 |

## 4. 测试与评测

| 层次 | 方式 | 状态 |
|---|---|---|
| 运行时 | `make selftest`：贪吃蛇用例要全部通过（约 60 fps）；`sandbox-escape.html` 的四类外网访问必须全部被拦截，错误必须带文件和行号 | ✅ |
| 引擎 | `make engine-check`；用无效 Key 走完整链路，Anthropic 和 OpenRouter 都必须快速失败（约 8–11 s） | ✅ |
| 端到端 | `AGENTOS_AUTOPROMPT` 自动生成应用，检查截图和日志 | ✅（需要真实 Key） |
| **评测集**（P1） | 10 个经典游戏（贪吃蛇、俄罗斯方块、坦克大战、打砖块、2048、扫雷、Flappy、太空侵略者、乒乓、迷宫），加上协议演示（笔记和待办） | 待建 |
| 契约测试（P1） | 应用接口与 schema 一致（[05](05-app-protocol.md)） | 待建 |

**评测指标：**
- 一次通过率：冒烟测试和契约测试都通过；
- 首次可玩时间；
- 单个应用的成本；
- 修复轮数；
- 接口覆盖率：`interface` 声明了的工具是否都能调用。

## 5. 日志与诊断

| 位置（`~/Library/Application Support/AgentOS/`） | 内容 |
|---|---|
| `logs/agentos-<时间>.jsonl` | 宿主事件，每次启动一个文件：`launched`、`engine_started`、`engine_stderr`、`prompt`、`prompt_result`、`runtime_call`、`smoke_test`、`error`…… |
| `logs/selftest-*.json` / `*.png` | 自测结果和截图 |
| `agent/projects/<cwd>/<session>.jsonl` | Agent SDK 的会话记录，包括 API 错误和重试的详情 |
| `meta/<appId>/` | 应用清单和对话记录 |

排查问题时，先看 `logs/`，再看 `agent/` 里对应会话的 `api_error`。

## 6. 协作流程

- **分支**：新功能在 `feat/*` 分支开发，文档在 `docs/*` 分支，通过 PR 合入 `main`。
- **提交**：提交说明用英文的 conventional commits 格式（`feat:`、`fix:`、`docs:`……）；由 Claude 参与的提交，结尾带上 `Co-Authored-By` 署名。
- **文档**：`docs/architecture/` 是正式方案，修改设计时同步更新对应分册，并在总览里补一条决策记录；调研过程记录在 `docs/research/`。
- **仓库**：https://github.com/dyman1024/AgentOS （公开仓库，提交前确认没有 Key、本机路径等敏感信息）。

## 7. 发布（规划）

- AgentOS 本体：用 Developer ID 签名并公证，用 Sparkle 做自动更新（Ed25519 签名），在官网直接分发。
- 应用的签名与 AgentOS 本体的签名严格分开（[04](04-app-package.md) 第 7 节）。
