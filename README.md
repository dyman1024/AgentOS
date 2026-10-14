# AgentOS

macOS 上的「对话即应用」：右侧和 Agent 对话，左侧即时生成并运行对应的应用或游戏，宿主 App 全程不需要重新编译。

整体方案与调研见 [docs/research/architecture-research.md](docs/research/architecture-research.md)。

## 当前阶段：P0 原型

- **外壳**：SwiftUI 窗口，左侧是运行时，右侧是对话。左侧未打开应用时显示启动台。
- **运行时**：每个应用一个 `WKWebView`，从 `agentos://<appId>/` 加载 `~/Library/Application Support/AgentOS/apps/<appId>/`。
  - 网络隔离靠两层：CSP 和 `WKContentRuleList`，拦截所有外网请求。
  - 每个应用有独立的 `WKWebsiteDataStore`。
  - 注入 [agentos-shim.js](App/Runtime/agentos-shim.js)，负责捕获 console 和异常、统计动画帧数、提供 `agentos.expose()`、模拟按键与点击。
- **Agent**：[agent-engine/](agent-engine/) 基于 Claude Agent SDK（TypeScript），用 Bun 编译成单文件作为子进程运行，与 Swift 之间走 stdio 上的 JSON-RPC。
  - 可用的文件工具只有 `Read / Write / Edit / Glob`，且限定在应用目录内。
  - 运行时工具 `run_app / smoke_test / send_input / get_console / screenshot / inspect_state / set_app_info` 由 Swift 实际执行。
  - Agent 写完文件后，左侧自动刷新；随后 Agent 自己运行、冒烟测试、截图检查，有问题就修复。
- **模型服务商**：在设置（⌘,）里二选一。
  - **Anthropic**：直连官方 API。
  - **OpenRouter**：走 OpenRouter 的 Anthropic 兼容接口，引擎按[官方文档](https://openrouter.ai/docs/guides/community/anthropic-agent-sdk)设置 `ANTHROPIC_BASE_URL` 和 `ANTHROPIC_AUTH_TOKEN`。预设了 Claude 系列和几款实验性模型，也可以填写任意 OpenRouter 模型 ID。
  - 选了不支持图片的模型时，Agent 的截图工具会被关闭；不是 Claude 的模型，不传思考强度参数。
  - 通过 OpenRouter 时，对话里显示的费用是按 Anthropic 定价估算的，以 OpenRouter 账单为准。
- **API Key**：用户自己填写，每个服务商一份。保存前会在线校验，无效的 Key 不会保存。Key 存在钥匙串里，生成的应用读不到。

## 开发

环境要求：macOS 15+、Xcode 26、[XcodeGen](https://github.com/yonaskolb/XcodeGen)、[Bun](https://bun.sh)。

```bash
cd agent-engine && bun install && cd ..
```

```bash
make run
```

`make run` 会生成 Xcode 工程、编译并打开 App。你也可以执行 `make project`，然后用 Xcode 打开 `AgentOS.xcodeproj`。

### 常用命令

| 命令 | 作用 |
|---|---|
| `make build` | 编译。构建阶段会把 Agent 引擎和 claude 二进制打进 `AgentOS.app/Contents/Resources/engine/` |
| `make selftest` | 不调用模型：把 [tests/fixtures/snake.html](tests/fixtures/snake.html) 载入运行时并跑冒烟测试，结果写入 `logs/selftest-result.json` |
| `make engine-check` | 对 Agent 引擎做 TypeScript 类型检查 |

### 调试开关

| 开关 | 作用 |
|---|---|
| `AGENTOS_ENGINE_CMD="bun run $PWD/agent-engine/src/index.ts"` | 用源码直接运行引擎，改引擎代码后不用重新编译 App |
| `AGENTOS_AUTOPROMPT="做个贪吃蛇" AGENTOS_AUTOQUIT=1` | 启动后自动发送这条请求，完成后截图并退出 |
| `--selftest-runtime <file.html>` | 把任意 HTML 当作应用跑一遍冒烟测试 |
| `-provider openrouter` / `-provider anthropic` | 本次启动临时切换服务商，不写入设置 |
| `ANTHROPIC_API_KEY` / `OPENROUTER_API_KEY` | 钥匙串里没有 Key 时，改用这里的 Key |

### 数据位置

所有数据都在 `~/Library/Application Support/AgentOS/` 下：

| 目录 | 内容 |
|---|---|
| `apps/` | 生成的应用代码 |
| `meta/` | 应用清单和对话记录 |
| `agent/` | Agent 会话 |
| `logs/` | 每次启动一个 JSONL 事件日志 |

### 签名

默认使用 ad-hoc 签名，每次重新编译后签名都会变，读取钥匙串时 macOS 可能再次弹窗，选「始终允许」即可。想避免这个弹窗，可以新建 `Config/Local.xcconfig`（已加入 .gitignore），改用你自己的开发者证书，写法见 [Config/AgentOS.xcconfig](Config/AgentOS.xcconfig)。
