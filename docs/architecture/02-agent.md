# 02 Agent 引擎

> 所属：[技术方案总览](README.md) ｜ 相关：[00 内核](00-kernel.md)、[03 运行时](03-app-runtime.md)、[05 协议](05-app-protocol.md)、[06 总线](06-event-bus.md)、[09 安全](09-security.md)
>
> 依据：[architecture-research.md](../research/architecture-research.md) 第 4 节、[tech-assessment.md](../research/tech-assessment.md) 第 3.11 节和第 6 节

## 1. 职责

- **Operator**：直接替用户办事，比如搜索、整理、读写数据、调用应用、主动订阅事件和执行自动化；需要造应用时交给 Builder。
- **Builder**：生成和修改应用，产出代码、接口、Skill 和契约测试，并通过自测闭环保证应用可用。
- **运行**：每一次自主工作都是内核里的一个运行（[00](00-kernel.md) 第 3.3 节），引擎按运行来执行、上报用量、接受取消。
- **模型接入**：对接多个服务商，按场景选择模型和思考强度。
- **记忆与个性化**：用户档案、偏好，以及每个应用的规格说明。

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
- **Hooks**：`PreToolUse` 把文件路径限制在应用目录内（检查 `file_path` 和 `path`；P1a 补上 `Glob` 的 `pattern`）；`PostToolUse`（Write/Edit）通知宿主文件已变化。
- **会话**：每个应用有自己的 `sessionId`，记在清单里，后续请求用 `resume` 接上；会话记录存在 `agent/` 目录（`CLAUDE_CONFIG_DIR`）。
- **系统提示**：`prompt.ts`，内容是运行时合约、`agentos.expose` 的要求和工作流程。保持字节不变，以便命中提示缓存。
- **快速失败**：鉴权、余额、模型不存在这类错误，在第一次重试时就中止；其他错误在对话里显示「正在重试 n/N」。
- **服务商**：

  | 服务商 | 环境变量 | 模型 |
  |---|---|---|
  | Anthropic | `ANTHROPIC_API_KEY` | 默认 `claude-opus-5-5`，思考强度默认 medium |
  | OpenRouter | `ANTHROPIC_BASE_URL=https://openrouter.ai/api`、`ANTHROPIC_AUTH_TOKEN`；`ANTHROPIC_API_KEY` 必须设为空字符串；后台小任务用 `anthropic/claude-haiku-5.5` | 预设 `anthropic/claude-opus-5.5` 等；非 Claude 模型属于实验性支持：不传思考强度，不支持图片输入的模型关掉截图工具 |

## 3. 目标设计

### 3.1 两种角色与会话模型

| | Operator | Builder |
|---|---|---|
| 入口 | 全局对话（启动台状态下的对话）、自动化、事件 | 绑定到某个应用的对话；Operator 移交（`apps.create`、`apps.modify`） |
| 工作目录 | 无固定目录；P3 起可以用 VM 的工作区 | 应用的 `src/` |
| 会话 | 全局对话一个会话；每次自动化触发一个独立的短会话 | **每个应用一个长期会话**，保证同一个应用的修改上下文连续 |
| 主要工具 | 元工具、数据工具、系统服务工具、自动化工具、包管理工具 | 文件工具、运行时工具、包管理工具、数据工具（读 schema 和样例数据） |
| 交付物 | 任务结果；必要时提议「固化成应用」 | 代码、`interface.json`、`SKILL.md`、`SPEC.md`、契约测试和冒烟测试 |

- 两种角色共用同一个引擎进程，区别在于系统提示、工具集和 Skill。
- **移交**：Operator 调用 `apps.create(request)` 或 `apps.modify(appId, request)`。宿主创建应用（或找到已有应用），把 Builder 的运行登记为 Operator 运行的子运行，外壳切到这个应用，Builder 的进度出现在对话里。Builder 结束后，结果回到 Operator 的运行。
- **P0 到 P1a 的变化**：P0 在启动台状态下一发消息就新建应用；P1a 起，启动台状态下的对话交给 Operator（雏形：只有元工具、数据工具和 `apps.create`），由它判断是办事还是造应用。

### 3.2 工具体系

| 类别 | 例子 | 由谁执行 | 谁能用 | 阶段 |
|---|---|---|---|---|
| 文件 | Read / Write / Edit / Glob | 引擎，限定在应用 `src/` | Builder | P0 |
| 运行时 | run_app、smoke_test、send_input、get_console、screenshot、inspect_state、call_tool、run_contract_tests | 宿主（[03](03-app-runtime.md) 第 3.4 节） | Builder | P0 / P1a |
| 包管理 | app.create、app.commit、app.versions、app.diff、app.rollback | 宿主（[04](04-app-package.md)） | 两者 | P1a |
| 元工具 | apps.search、apps.describe、apps.call | 宿主（[05](05-app-protocol.md) 第 9 节） | 两者 | P1a |
| 数据 | data.query、data.get、data.put、data.delete、data.history、data.restore | 宿主（[08](08-data.md) 第 4 节） | 两者 | P1a |
| 移交 | apps.create、apps.modify | 宿主 | Operator | P1a |
| 自动化 | automation.create / list / update / delete | 宿主（第 3.4 节） | Operator | P1b |
| 系统服务 | web.search、web.fetch、browser.open、publish、notify、mail.* …… | 宿主（[07](07-system-services.md)） | Operator | P2 起 |
| VM | vm.exec、vm.fs.* | Workbench VM（[10](10-workbench-vm.md)） | 两者 | P3 |

- **除了 Builder 的文件工具，所有工具都由宿主执行**：引擎把它们注册成 Agent SDK 的进程内 MCP 工具，调用时经 JSON-RPC 转给宿主（第 3.6 节），宿主走检查点、记审计、算标签。引擎本身不持有任何权限。
- **不开放 SDK 内置的 Bash、WebFetch、WebSearch**：它们会在宿主机上以用户身份直接执行，绕过检查点。需要的能力由宿主的系统服务和 VM 提供。
- **应用工具不直接暴露**：P1 只通过三个元工具访问（[05](05-app-protocol.md) 第 9 节）。工具集在会话开始时固定，保证提示缓存稳定。

### 3.3 Builder 的生成、验证、修复闭环

1. **路由**：判断是新建、修改还是提问，选择模板 Skill（canvas-game、notes-like、list-tool、dashboard、document……）。
2. **脚手架**：包管理创建应用和 `src/`；运行时打开一个预热好的界面 WebView。
3. **生成，按顺序**：
   1. `SPEC.md`：一段话写清用途和关键决定；
   2. 数据模型：复用哪些共享集合，或者新建哪个用户 schema（[08](08-data.md) 第 3 节）；
   3. `interface.json`：工具、数据、订阅；
   4. `core.js`：实现工具和订阅；
   5. `tests/contract.json`：每个工具至少一个正例、一个反例；
   6. `ui/`：界面，修改数据一律调用自己的工具；
   7. `SKILL.md`。

   先接口、后界面，是为了让界面成为接口的第一个调用方（[05](05-app-protocol.md) 第 1 节）。纯游戏可以跳过第 2–5 步里不需要的部分。
4. **自测**：
   - `run_contract_tests`：契约测试全部通过；
   - `run_app` → `smoke_test`（检查项：no_errors、nonblank、frames_advancing、visual_change、state_changes，按应用类型选择）；
   - 新应用截一张图做视觉检查。
5. **修复**：用 Edit 增量修改，最多 3 轮；同一个错误出现两次就停下来报告；str_replace 连续失败两次就整文件重写。
6. **提交**：调用 `app.commit`，宿主执行安装流程（[04](04-app-package.md) 第 6 节）：校验、申请权限、跑测试、生成版本、注册接口。

### 3.4 自动化（Agent 主动订阅）

- Agent 可以订阅**任何**事件（[06](06-event-bus.md)），不需要逐项授权（创始人决策）。**订阅的落地形式就是自动化**：事件到达时，宿主创建一个运行来处理它，而不是把事件塞进某个进行中的对话。
- **自动化 = 触发条件 + 计划 + 限制**：

  ```jsonc
  { "id": "auto_7f", "createdBy": "run:run_01JB…",       // 或 user
    "trigger": { "event": "mail.received", "filter": { "from": "*@partner.com" } },   // 或 { "schedule": "0 9 * * 1-5" }
    "plan": { "goal": "把会议邀请加入日历，需要时回信确认",
              "tools": ["mail.get", "calendar.create", "mail.send"],   // 创建时固定，事件内容无法扩大范围
              "constraints": { "mail.send": { "to": "$event.from" } } },  // 出口参数的约束
    "limits": { "maxRunsPerDay": 50, "maxCostUsdPerDay": 2 },
    "mode": "inherit",                                      // 跟随全局权限模式
    "enabled": true }
  ```

- **创建时的把关**（[09](09-security.md) 第 4.3 节）：计划里含 `irreversible` 出口（例如 `mail.send`）的自动化，相当于预先授予了未来无数次对外操作，所以在谨慎和自动模式下，创建和修改都要用户确认；只含读写的自动化直接创建，在活动流里通知。
- **执行流程**：
  1. 事件到达 → 宿主检查过滤条件和每日上限 → 创建运行，委托链 = 创建者 → 自动化 → 运行。
  2. 事件或它指向的内容不可信时，先用**单次模型调用**（第 3.5 节）把内容解析成计划需要的结构化字段；解析结果仍带污点。
  3. Operator 按计划执行，只能调用白名单里的工具，出口参数受约束检查。
  4. 结果写入活动流，所有调用记入审计。

### 3.5 两种执行方式

| 执行方式 | 用于 | 实现 |
|---|---|---|
| **完整 Agent** | Builder、交互式 Operator、多步骤的自动化 | Agent SDK `query()`，每个会话一个 claude 子进程 |
| **单次模型调用** | 隔离解析不可信内容、意图路由、起名、给活动流写摘要、自动化里的简单分类 | 引擎里直接调用 Messages API（官方 TS SDK，沿用同样的 `ANTHROPIC_BASE_URL`），结构化输出，**不带任何工具** |

隔离解析本来就不该有工具，用完整的 Agent SDK 反而多了风险面和进程开销。单次调用的费用同样计入运行。

### 3.6 宿主与引擎之间的协议（P1a 起）

在 P0 协议的基础上：

| 方向 | 方法 | 变化 |
|---|---|---|
| 宿主 → 引擎（请求） | `session/prompt` | 增加 `runId`、`role`（operator / builder / automation）、`cwd`、`toolProfile`（这个角色能用哪些工具）、`budgetUsd`；去掉 `appDir`（由 `cwd` 取代） |
| 宿主 → 引擎（通知） | `session/cancel` | 参数改为 `{runId}` |
| 引擎 → 宿主（请求） | `tool/call` | `{runId, name, args}`：除文件工具外的所有工具，宿主执行后返回结果；取代 `runtime/<tool>` |
| 引擎 → 宿主（通知） | `run/usage` | `{runId, model, inputTokens, outputTokens, cacheReadTokens, costUsd}`，每条模型回复后发一次；**宿主据此记账，超预算就取消运行**（[00](00-kernel.md) 第 10 节） |
| 宿主 → 引擎（请求） | `llm/complete` | `{runId, model, system, input, schema}` → 结构化结果；第 3.5 节的单次模型调用 |
| 引擎 → 宿主（通知） | `session/update` | 改为按 `runId` 归属，`kind` 取值不变 |

宿主核对每个 `tool/call` 的 `runId` 属于这个引擎进程的活动运行（[00](00-kernel.md) 第 4 节）。

### 3.7 记忆与个性化

| 记忆 | 内容 | 存储 | 阶段 |
|---|---|---|---|
| 应用规格说明 | 用途、关键设计决定、已知问题；Builder 每次修改后更新，保证意图能跨会话延续 | 应用 `src/SPEC.md` | P1a |
| 会话 | 对话和工具调用的完整记录 | `system/agent/`（Agent SDK 自己管理） | P0 |
| 用户档案 | 称呼、语言、偏好（例如「博客用轻松的语气」）、常用账号 | 数据层的 `profile` 集合 | P2 |
| 情景记忆 | Agent 自己记下的经验，例如「这个用户的邮件服务器要用应用专用密码」 | 数据层的 `memory` 集合 | P2 |

### 3.8 模型与成本

- **模型选择**：默认一个强模型，按回合调整思考强度。单次模型调用默认用小模型（`claude-haiku-5-5`）。只有在评测证明划算时，才在完整 Agent 里引入多模型分流，因为提示缓存是按模型分开的。
- **预算**：单个运行默认 3 美元；自动化有每日费用和次数上限；全局还有每日上限。**全部由宿主记账执行**，不依赖 SDK 的 `maxBudgetUsd`（它是客户端估算，可能超支）。
- **缓存**：系统提示和工具定义保持字节稳定；会变化的上下文放在后面。
- **数据流出**：Agent 读到的内容会发给模型服务商。实验性模型默认不能接收 `private` 数据（[09](09-security.md) 第 9 节）。
- **本地模型**：可以通过 Ollama 的 Anthropic 兼容接口接入，作为低成本或离线的选项（P4）。

### 3.9 并发与优先级

- 同时运行的完整 Agent 不超过 3 个（每个都是一个 claude 子进程），其余排队；交互式运行优先于自动化。
- 同一个应用同时只有一个 Builder 运行；Builder 运行期间，该应用的核心照常处理调用，但热重载按 [03](03-app-runtime.md) 第 4.5 节暂停投递。

### 3.10 引擎可替换

宿主和引擎之间的协议按 ACP（Agent Client Protocol）的形状设计。ACP 已经有 Codex、Gemini CLI、OpenCode 等实现，Claude 也有基于 Agent SDK 的 `claude-agent-acp` 适配器（由 ACP/Zed 维护）。将来换引擎时，外壳不用改；但宿主需要的是工具转发、用量上报和取消，这些超出了 ACP 的对话协议，所以不急于实现 ACP 本身。

## 4. 评测

| 评测集 | 内容 | 阶段 |
|---|---|---|
| 游戏 | 10 个经典游戏（贪吃蛇、俄罗斯方块、坦克大战、打砖块、2048、扫雷、Flappy、太空侵略者、乒乓、迷宫） | P1a |
| 协议 | 笔记、待办、书签、记账本：接口和契约测试的一次通过率；界面任务中只靠接口能完成的比例 | P1a |
| Operator | 「本周有什么待办」「把这三条笔记合并」这类跨应用任务的成功率和工具调用次数 | P1a / P1b |
| 注入 | 埋了注入文本的网页和邮件：是否出现未经确认的出口调用 | P2 |

指标定义见 [11](11-engineering.md) 第 4 节。

## 5. 里程碑

| 阶段 | 内容 |
|---|---|
| P0 ✅ | Builder 和运行时工具；流式代码展示；两个服务商；快速失败 |
| P1a | 协议升级（`runId`、`tool/call`、`run/usage`、`llm/complete`）；Operator 雏形和移交；Builder 按新顺序生成核心、接口和契约测试；元工具和数据工具；宿主记账；`SPEC.md`；评测集 v0 |
| P1b | 自动化（数据事件和定时触发）及其创建把关；订阅 `task.*` 这类 Agent 订阅 |
| P2 | Operator 完整版：搜索和浏览器工具、记忆、固化成应用 |
| P3 | 隔离解析加先计划后执行（配合邮件服务）；VM 工具；代码模式 |
| P4 | 原生应用的构建工具；本地模型 |

## 6. 风险

- 应用多次迭代后容易变质：靠 `SPEC.md`、契约测试和冒烟测试约束。
- 自动化可能失控（循环、费用）：靠事件深度上限、频率上限和宿主记账的费用上限兜底。
- 每个完整 Agent 会话一个 claude 子进程，常驻内存可观；靠并发上限和单次模型调用分流。
- 非 Claude 模型的工具调用质量不稳定，只作为实验性支持。

## 重建引擎契约（2026-10-16）

引擎入口改为 `agent-engine/src/rebuild.ts`。Claude Agent SDK 的内置文件、终端工具关闭，应用和系统能力通过宿主工具提供；工作目录只保存该引擎的会话。会话按主体、服务商、模型、角色和应用区分，委托不会把应用升级为用户权限。

运行先预留预算，再执行请求。Operator 为自身模型预留运行额度的 25%，给 Builder 和系统工具留余量；Builder 预留 85%。子运行从父运行预留额度，结束后按子运行总成本结算，失败或缺少用量时保守记账。SDK 的单轮响应可能超过停止阈值，因此这是宿主预算约束，不是服务商账单的绝对硬上限。运行 30 分钟超时先取消，10 秒仍未停止则终止引擎。

Builder 默认生成 Web 应用，也收到原生 Swift 与 WASM 的文件、SDK 和测试约定。`workspace.write` 支持 UTF-8 或 base64 二进制资产，单文件不超过 2 MB。付费生成质量以 `evals/generation.py` 实跑结果为准；默认命令只打印计划，不调用模型。

评测入口已建立：S3 比较元工具与 SDK Tool Search，记录是否真正使用了 Tool Search；不支持时标记不可比较，不当成该策略通过。S4 用四类独立任务逐项调用生成工具并核对共享数据，不以 Builder 自带测试代替接口覆盖率。S6 使用本地研究素材与真实模型/内核出口策略。三者默认 dry run，真实质量结果尚未产生。

修复闭环必须接收失败用例和编译详情。JSON-RPC 保留结构化 diagnostics，SDK 工具错误文本限制 16000 字符；详情可能包含源码或私人测试数据，宿主先传播保守私人/诊断来源标签，实验性模型不接收这些内容。委托运行创建失败会退回父运行的预算预留。
