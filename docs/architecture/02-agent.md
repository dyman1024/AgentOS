# 02 Agent 引擎

> 所属：[技术方案总览](README.md) ｜ 相关：[03 运行时](03-app-runtime.md)、[05 协议](05-app-protocol.md)、[06 总线](06-event-bus.md)、[09 安全](09-security.md)

## 1. 职责

- **Builder**：生成和修改应用，产出代码、接口、Skill 和契约测试，并通过自测闭环保证应用可用。
- **Operator**：直接替用户办事，比如搜索、整理、读写数据、调用应用、在 VM 里执行命令、主动订阅事件和执行自动化。
- **模型接入**：对接多个服务商，按场景选择模型和思考强度。
- **工具体系**：文件工具、运行时工具、元工具、系统服务工具、VM 工具，以及按需加载机制。
- **记忆与个性化**：用户档案、偏好，以及每个应用的规格说明。
- **成本控制**：预算上限、提示缓存、模型路由。

## 2. 现状（P0）

### 2.1 进程结构

```
AgentOS.app ──Process + stdio（NDJSON，JSON-RPC 2.0）──▶ agentos-engine（Bun 编译的单文件）
                                                           └─ Claude Agent SDK 的 query()
                                                               └─ 内置的 claude 二进制（约 248 MB）
```

- 引擎源码在 `agent-engine/src/`。构建时，`scripts/bundle-engine.sh` 把引擎和 claude 二进制一起打进 `AgentOS.app/Contents/Resources/engine/`。
- 宿主侧的客户端是 `App/Agent/EngineClient.swift`：负责拉起进程、按行切分消息、匹配请求和响应、处理退出。
- 引擎在 API Key 或服务商变化时重启；对话请求触发时如果引擎没在运行，会自动拉起。

### 2.2 宿主与引擎之间的协议

| 方向 | 方法 | 参数和返回 |
|---|---|---|
| 宿主 → 引擎（请求） | `session/prompt` | `{appId, appDir, text, sessionId?, model, effort?, vision, maxBudgetUsd}` → `{sessionId, cancelled, isError, subtype, resultText, costUsd, durationMs, numTurns, usage}` |
| 宿主 → 引擎（通知） | `session/cancel` | `{appId}` |
| 引擎 → 宿主（通知） | `session/update` | `{appId, update}`，其中 `update.kind` 取值见下 |
| 引擎 → 宿主（请求） | `runtime/<tool>` | `{appId, ...args}`，由宿主操作 WebView 执行（见 [03](03-app-runtime.md)） |

`update.kind` 的取值：

| kind | 含义 |
|---|---|
| `session_started` | 会话已建立，携带 sessionId |
| `text_delta` | 回复文本的增量 |
| `tool_start` / `tool_call` / `tool_result` | 工具调用开始、完整参数（文件内容被裁掉）、调用结果 |
| `tool_progress` | 正在写入的代码（流式解析出 Write/Edit 的内容，每 200ms 发一次，只带最后 40 行） |
| `file_changed` | 文件已修改，宿主据此自动重载 |
| `api_retry` | API 请求失败、正在重试，附带尝试次数和 HTTP 状态 |

### 2.3 Agent 配置（`agent-engine/src/index.ts`）

- **工具**：内置工具只开放 `Read`、`Write`、`Edit`、`Glob`；运行时工具以 `mcp__runtime__*` 的形式提供（`runtimeTools.ts`）。
- **权限**：`permissionMode: 'dontAsk'`，加上 `allowedTools` 白名单；`settingSources: []`，不读取用户本机的 Claude 配置。
- **Hooks**：`PreToolUse` 把所有文件路径限制在应用目录内；`PostToolUse`（Write/Edit）通知宿主文件已变化。
- **会话**：每个应用有自己的 `sessionId`，记在清单里，后续请求用 `resume` 接上；会话记录存在 `agent/` 目录（`CLAUDE_CONFIG_DIR`）。
- **系统提示**：`prompt.ts`，内容是运行时合约、`agentos.expose` 的要求和工作流程。保持字节不变，以便命中提示缓存。
- **快速失败**：鉴权、余额、模型不存在这类错误，在第一次重试时就中止；其他错误在对话里显示「正在重试 n/N」。
- **服务商**：

  | 服务商 | 环境变量 | 模型 |
  |---|---|---|
  | Anthropic | `ANTHROPIC_API_KEY` | 默认 `claude-opus-5-5`，思考强度默认 medium |
  | OpenRouter | `ANTHROPIC_BASE_URL=https://openrouter.ai/api`、`ANTHROPIC_AUTH_TOKEN`；`ANTHROPIC_API_KEY` 必须设为空字符串；后台小任务用 `anthropic/claude-haiku-5.5` | 预设 `anthropic/claude-opus-5.5` 等；非 Claude 模型属于实验性支持：不传思考强度，不支持图片输入的模型关掉截图工具 |

## 3. 目标设计

### 3.1 两种角色

| | Builder | Operator |
|---|---|---|
| 触发 | 「做个……」「把这个应用改成……」，或 Operator 移交 | 全局对话、自动化、事件 |
| 工作目录 | 应用的源码目录 | 无固定目录；可以用 VM 的工作区 |
| 主要工具 | 文件工具、运行时工具、包管理工具、`exec`（构建 B 类应用） | 元工具、应用工具（按需加载）、系统服务工具、`exec` 和 `fs`、自动化工具 |
| 交付物 | 代码、`interface`、`SKILL.md`、契约测试、冒烟测试、应用规格说明 | 任务结果；必要时建议「固化成应用」 |

两种角色共用同一个引擎，区别在于系统提示、工具集和 Skill。

### 3.2 工具体系

| 类别 | 例子 | 由谁执行 | 加载方式 |
|---|---|---|---|
| 文件 | Read / Write / Edit / Glob | 引擎，限定在应用目录 | Builder 常驻 |
| 运行时 | run_app、smoke_test、send_input、get_console、screenshot、inspect_state | 宿主（[03](03-app-runtime.md)） | Builder 常驻 |
| 包管理 | app.create、app.build、app.install、app.rollback、app.versions | 宿主（[04](04-app-package.md)） | 常驻 |
| 元工具 | apps.search、apps.describe、apps.call、events.subscribe、events.list、automation.create / list / delete | 宿主（[05](05-app-protocol.md) / [06](06-event-bus.md)） | 常驻 |
| 应用工具 | `mail.search`、`notes.create` …… | 各应用，经宿主路由 | **按需加载**（工具搜索） |
| 系统服务 | web.search、web.fetch、data.query、notify …… | 宿主（[07](07-system-services.md)） | 常用的常驻，其余按需 |
| VM | exec、fs.read / write、service.start | Workbench VM（[10](10-workbench-vm.md)） | Operator 常驻 |

- **按需加载**：应用工具全部延迟加载，Agent 通过 `apps.search` 或工具搜索找到后再载入，避免几百个应用的工具撑爆上下文。
- **代码模式**：批量操作时，为每个应用生成带类型的接口存根（如 `apps/mail.ts`），让 Agent 写一段代码在 VM 里执行，而不是一个个地调用工具。

### 3.3 Builder 的生成、验证、修复闭环

1. **路由**：判断请求是新建、修改还是提问，并选择模板 Skill（canvas-game、dom-tool、notes-like、dashboard……）。
2. **脚手架**：包管理创建应用，生成 `v0`；运行时打开一个预热好的空白 WebView。
3. **生成**：先写代码；**再写 `interface`、`SKILL.md`、契约测试**（P1 起强制）。代码流式写入时，对话里实时显示进度。
4. **自测**：
   - run_app → smoke_test（检查项：no_errors、nonblank、frames_advancing、visual_change、state_changes）。
   - 新应用再截一张图做视觉检查。
   - P1 起还要跑契约测试，逐个调用 interface 里的工具，检查输入输出是否符合 schema。
5. **修复**：用 Edit 增量修改，最多 3 轮；同一个错误出现两次就停下来报告；str_replace 连续失败两次就整文件重写。
6. **提交**：生成新版本（[04](04-app-package.md)），注册接口（[05](05-app-protocol.md)），申请权限（[09](09-security.md)），更新应用的规格说明。

### 3.4 主动订阅与自动化（创始人决策：Agent 可以主动订阅）

- Agent 可以订阅**任何**事件（[06](06-event-bus.md)），不需要逐项授权。
- **自动化** = 触发条件（事件类型加过滤条件，或定时）+ 计划 + 执行策略。

  ```jsonc
  { "id": "auto_7f", "createdBy": "agent | user",
    "trigger": { "event": "mail.received", "filter": { "from": "*@company.com" } },
    "plan": { "goal": "把会议邀请加入日历并在笔记里记要点",
              "tools": ["mail.get", "calendar.create", "notes.create"] },  // 创建时固定，事件内容无法扩大范围
    "limits": { "maxRunsPerDay": 50, "maxCostUsdPerDay": 2 },
    "mode": "inherit" }  // 跟随全局权限模式
  ```

- **执行流程**：
  1. 事件到达后，不可信内容先交给**没有任何工具的隔离模型**解析成结构化字段。
  2. Operator 按计划执行，只能调用计划里列出的工具。
  3. 结果写入活动流，所有调用记入审计日志。
- Agent 自己创建的自动化，会在活动流里通知用户，用户可以随时停用或删除。

### 3.5 记忆与个性化

| 记忆 | 内容 | 存储 |
|---|---|---|
| 用户档案 | 称呼、语言、偏好（例如「博客用轻松的语气」）、常用账号 | 数据层的 `profile` 集合 |
| 应用规格说明 | 应用的用途、关键设计决定、已知问题；Builder 每次修改后更新，保证意图能跨会话延续 | 应用源码目录里的 `SPEC.md` |
| 会话 | 对话和工具调用的完整记录 | `agent/`（Agent SDK 自己管理） |
| 情景记忆 | Agent 自己记下的经验，例如「这个用户的邮件服务器要用应用专用密码」 | 数据层的 `memory` 集合 |

### 3.6 模型与成本

- **模型选择**：默认一个强模型，按回合调整思考强度。只有在实测证明划算时，才引入多模型分流，因为提示缓存是按模型分开的。
- **预算**：每次请求有 `maxBudgetUsd`（默认 3 美元）；自动化有每日费用和次数上限；全局还有每日上限。
- **缓存**：系统提示和工具定义保持字节稳定；会变化的上下文放在后面。
- **本地模型**：可以通过 Ollama 的 Anthropic 兼容接口接入，作为低成本或离线的选项（P4）。

### 3.7 引擎可替换

宿主和引擎之间的协议按 ACP（Agent Client Protocol）的形状设计，所以将来可以换成其他 Agent 引擎（例如基于 ACP 的 Codex、opencode），或改成 Swift 原生的循环，外壳不用改。

## 4. 里程碑

| 阶段 | 内容 |
|---|---|
| P0 ✅ | Builder 和运行时工具；流式代码展示；两个服务商；快速失败 |
| P1 | Builder 必须交付接口；元工具和按需加载；`events.subscribe` 和 `automation.*`；活动流写入；`SPEC.md` |
| P2 | Operator 角色；VM 工具；搜索和浏览器工具；代码模式；记忆 |
| P3 | 隔离模型解析加先计划后执行（配合邮件服务）；原生应用的构建工具 |
| P4 | 本地模型；自动化市场和模板 |

## 5. 风险

- 应用多次迭代后容易变质，靠 `SPEC.md`、契约测试和冒烟测试来约束。
- 自动化可能失控（循环、费用），靠深度上限、频率上限和费用上限兜底。
- 非 Claude 模型的工具调用质量不稳定，只作为实验性支持。
