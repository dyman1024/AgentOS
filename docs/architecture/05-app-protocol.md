# 05 应用协议（接口定义、MCP、CLI）

> 所属：[技术方案总览](README.md) ｜ 相关：[00 内核](00-kernel.md)、[03 运行时](03-app-runtime.md)、[06 事件总线](06-event-bus.md)、[08 数据层](08-data.md)、[02 Agent](02-agent.md)
>
> 依据：[system-architecture.md](../research/system-architecture.md) 第 4 节、[tech-assessment.md](../research/tech-assessment.md) 第 3.5–3.7 节和第 6 节

## 1. 定位

**这是 AgentOS 最核心的差异化：所有应用天然支持同一套协议。**

- **每个应用一诞生就带着接口**：工具、它读写的数据集合、它订阅和调用的东西。Builder 必须和代码一起交付（[02](02-agent.md) 第 3.3 节）。
- **宿主是唯一的调用方和中转。** 应用之间不能直接通信，Agent 也不能直连应用；所有调用都经过宿主的路由和检查点（[00](00-kernel.md) 第 5 节）。
- **接口定义（IDL）是真相源。** 应用的 `interface.json` 描述接口；给 Agent 的元工具、给原生和 VM 应用的 MCP、给终端和脚本的 `aos` CLI、给代码模式的 TS 存根，都是从它生成的**投影**。MCP 再有不兼容的大改（2026-07-28 就是一次），只影响一个投影。
- **界面是接口的第一个调用方。** 应用分为无界面核心和界面（[03](03-app-runtime.md) 第 4 节）。工具都在核心里；界面修改用户数据也要调用这些工具。所以用户在界面上能做的事，Agent 通过接口也都能做。

```
Agent（元工具）──┐
aos CLI ────────┼──▶ ┌──────── 宿主：路由 + 检查点 ────────┐ ──▶ 应用核心（隐藏 WebView）
应用界面 ────────┤    │ 身份 · 授权 · 出口策略 · 审计 · 标签 │ ──▶ 原生进程 / VM 服务（MCP）
其他应用的核心 ──┘    └─────────────┬──────────────────────┘
                                    └── 事件总线（06）· 数据层（08）
```

## 2. 接口定义（IDL）

### 2.1 文件

```
apps/<id>/src/interface/
├── interface.json        # 接口定义，唯一的真相源
└── schemas/              # 应用私有的类型（可选）；共享类型直接引用 agentos:schema/…
```

```jsonc
{
  "schema": "agentos.interface/1",
  "id": "tasks",                    // 期望的命名空间；最终由宿主分配并保证唯一（第 3 节）
  "version": "1.2.0",               // 接口自己的语义化版本，和应用版本分开（第 5 节）
  "summary": "待办事项：查询、新建、完成任务，并从笔记里抽取 TODO",
  "tools": [ /* 第 2.2 节 */ ],
  "data": [                          // 读写哪些共享集合（08）
    { "collection": "tasks", "access": "rw" },
    { "collection": "notes", "access": "r" } ],
  "subscribes": [ { "pattern": "note.created" }, { "pattern": "note.updated" } ],   // 06
  "calls": [ "notes.get" ],          // 调用其他应用的工具
  "emits": [],                       // 应用自定义事件，P2 起开放（06 第 3 节）
  "ui": []                           // 可以嵌入其他界面的视图，兼容 MCP Apps，P3 起
}
```

`data`、`subscribes`、`calls` 都是**申请**，安装时转成能力授权（[09](09-security.md) 第 5 节）。

### 2.2 工具

```jsonc
{ "name": "list",                                   // 本地名；全名是 <命名空间>.<本地名>，例如 tasks.list
  "title": "列出待办",
  "description": "按日期范围列出待办，默认本周，按截止时间排序",
  "input":  { "type": "object",
              "properties": { "range": { "enum": ["today", "week", "all"], "default": "week" } } },
  "output": { "type": "object",
              "properties": { "items": { "type": "array", "items": { "$ref": "agentos:schema/task@1" } } },
              "required": ["items"] },
  "annotations": {
    "idempotent": true,       // 重复调用结果相同
    "interactive": false,     // true 表示需要用户在界面上操作（例如选文件）；不能被自动化调用，也不能无界面执行
    "longRunning": false      // true 表示可能超过 30 秒，返回任务句柄（第 4.3 节）
  },
  "examples": [ { "input": { "range": "today" } } ] }
```

- `input` 和 `output` 使用 JSON Schema 2020-12 的一个子集：`type`、`properties`、`required`、`enum`、`items`、`default`、`minimum` / `maximum`、`maxLength`、`format`（`date-time`、`uri`、`email`）、`$ref`。不允许 `oneOf`、`patternProperties` 这类难以校验、也难以投影成 CLI 参数的写法。
- 宿主在调用前校验输入，调用后校验输出。不符合 schema 的输出按错误处理，并计入契约测试。

### 2.3 副作用上限：由能力推导，不由应用声明

生成的工具内部是任意代码，宿主无法逐个判定它的副作用。但应用没有网络，**所有对外的副作用都必须经过宿主的出口服务**（[07](07-system-services.md)）。所以：

- 一个工具的副作用上限 = 它所在应用的能力授权所能触达的最高等级。
- 没有任何出口授权的应用（绝大多数），它的所有工具最多是 `write`。
- 真正的把关在出口被调用的那一刻执行（[09](09-security.md) 第 4 节），而不是在工具调用时。

| 应用持有的授权 | 工具的副作用上限 |
|---|---|
| 只有 `data.read` | `read` |
| `data.write` | `write` |
| `net`（只发 GET）、`web.*` | `fetch` |
| `calendar.create` 等可补偿的出口 | `external` |
| `mail.send`、`publish`、`net`（非 GET） | `irreversible` |

`apps.describe` 会把推导出的上限展示给 Agent，例如「这个工具可能对外发送」。

### 2.4 共享领域 schema

- 数据类型优先引用 `agentos:schema/<type>@<major>`，例如 `note`、`task`、`document`、`bookmark`、`contact`、`mail.summary`、`media.item`（定义见 [08](08-data.md) 第 3 节）。
- Builder 为新领域创建的类型（例如记账本的 `expense`）注册为用户 schema：`user:schema/<type>@<major>`，同样可以被其他应用引用。

## 3. 命名与归属

| 规则 | 说明 |
|---|---|
| 命名空间按应用分配 | `interface.id` 只是期望值。宿主按「先到先得」分配，冲突时加后缀（例如第二个笔记应用得到 `notes-2`），用户可以重命名。工具全名 = `<命名空间>.<本地名>` |
| 领域名留给数据层 | `data.*` 是数据层的工具（[08](08-data.md) 第 4 节）；应用不能用 `data`、`apps`、`events`、`system` 等保留名做命名空间 |
| 增删改查可以直接走数据层 | Agent 做纯粹的增删改查，直接用 `data.*` 即可。应用自己的增删改查工具主要服务于它的界面（界面只能通过工具改数据），可以附带应用自己的规则（例如自动打标签）；超出增删改查的行为（「从笔记抽取 TODO」「导出成 PDF」）只能是应用工具 |
| 共享集合没有归属应用 | 任何持有写授权的主体都能写。应用**不能假设自己是唯一写入者**；需要在每次写入时执行的逻辑，用订阅领域事件来实现（[06](06-event-bus.md)） |

## 4. 调用语义

### 4.1 请求与响应

```jsonc
// 宿主 → 应用核心
{ "tool": "tasks.list", "args": { "range": "week" },
  "_meta": { "runId": "run_01JB…", "traceparent": "00-…", "caller": "run:run_01JB…",   // 宿主填写，应用无法伪造
             "deadline": "2026-10-15T09:12:33Z" } }
// 应用核心 → 宿主
{ "structuredContent": { "items": [ … ] },   // 必须符合 output schema
  "content": [ { "type": "text", "text": "本周有 3 项待办" } ],   // 给 Agent 读的简短文本
  "isError": false }
```

### 4.2 错误

| 错误码 | 含义 | 谁返回 |
|---|---|---|
| `invalid_args` | 输入不符合 schema | 宿主（不会到达应用） |
| `denied` | 没有授权，或用户在确认框里拒绝；附原因 | 宿主 |
| `not_found` | 工具或对象不存在 | 宿主或应用 |
| `unavailable` | 应用核心启动失败或崩溃 | 宿主 |
| `timeout` | 超过截止时间 | 宿主 |
| `conflict` | 数据版本冲突（[08](08-data.md) 第 4 节） | 数据层 |
| `app_error` | 应用自己报告的业务错误，附可读的原因 | 应用 |

### 4.3 时长、取消与并发

- 默认截止时间 30 秒。`longRunning` 的工具立即返回任务句柄，进度和结果通过任务接口获取，语义对齐 MCP Tasks 扩展（P2 起）。
- 调用方可以取消；宿主通知应用核心，并且不再接收它的结果。
- 每个应用核心同时处理的调用默认不超过 8 个，超出就排队。
- 工具处理函数里可以再调用其他工具；调用深度上限 8，防止循环。

### 4.4 需要用户操作的工具

`interactive` 工具会打开应用界面，等待用户操作。它们不能被自动化调用，也不能在无界面状态下执行；Agent 调用时，外壳会把应用切到前台。

## 5. 版本与兼容

**「应用可抛」意味着应用 B 随时可能被重新生成；调用它的应用 A 和自动化不能因此坏掉。**

- `interface.version` 是接口自己的语义化版本。
- 安装或升级时（[04](04-app-package.md) 第 6 节），宿主比较新旧接口：

  | 变化 | 等级 |
  |---|---|
  | 新增工具、新增可选输入、输出新增字段 | 兼容（次版本） |
  | 删除工具、新增必填输入、改变字段类型、输出删除字段、收紧枚举 | **破坏性**（主版本） |

- 注册表知道谁依赖谁：其他应用的 `calls`、自动化的工具白名单、订阅。出现破坏性变化时，安装流程会列出受影响的依赖方。Builder 应当先尝试保持兼容；做不到时，由用户确认，或让 Builder 同时修改依赖方。
- 跨应用协作**优先依赖共享数据 schema**，而不是对方的工具。共享 schema 由 AgentOS 维护，字段只增不改（[08](08-data.md) 第 3 节）。

## 6. 各类运行时的传输方式

所有运行时的请求和响应内容一样，只是承载方式不同：

| 运行时 | 承载 | 阶段 |
|---|---|---|
| JS 应用核心 | 核心宿主（隐藏 WebView）：宿主用独立 content world 里的 `callAsyncJavaScript` 调用处理函数；应用经 `WKScriptMessageHandlerWithReply` 回调宿主 | P1a |
| JS 应用界面 → 自己的核心 | `agentos.self.call(…)` 先到宿主，再由宿主转给核心。多一跳（毫秒级），换来统一的检查点和审计 | P1a |
| 原生进程 | 以 `--mcp` 启动，stdio 上说 MCP | P4 |
| VM 服务 | vsock 上说 MCP，不暴露网络端口 | P3 |
| 远端应用、第三方 MCP 驱动 | Streamable HTTP + OAuth | P3 起 |

## 7. JS SDK（P1a，注入到核心和界面里）

```js
// core.js：只绑定处理函数；schema 写在 interface.json 里，代码里不重复
agentos.tools.register('list', async ({ range }) => {
  const items = await agentos.data.collection('tasks').query({ where: dueIn(range), orderBy: 'due' });
  return { items };
});

agentos.tools.register('extractFromNote', async ({ noteId }) => {
  const note = await agentos.call('notes.get', { id: noteId });       // 需要 calls 授权
  for (const line of note.body.split('\n').filter((l) => l.startsWith('TODO')))
    await agentos.data.collection('tasks').put({ title: line.slice(4).trim(), source: `note:${noteId}` });
});

agentos.events.subscribe('note.created', (ev) => agentos.self.call('extractFromNote', { noteId: ev.data.id }));
```

```js
// ui/index.html 里的脚本：读数据可以直接查，改数据必须调用自己的工具
const { items } = await agentos.self.call('list', { range: 'week' });
button.onclick = () => agentos.self.call('complete', { id });
```

| 接口 | 核心 | 界面 |
|---|---|---|
| `agentos.tools.register(name, handler)` | ✅ | — |
| `agentos.self.call(name, args)` | ✅ | ✅ |
| `agentos.call(fullName, args)` | ✅（需要 `calls` 授权） | — |
| `agentos.data.collection(name)` | 读写（按授权） | **只读** |
| `agentos.events.subscribe / emit` | ✅ | — |
| `agentos.expose(fn)` | — | ✅（自测用，见 03） |

规则：

- `register` 了 `interface.json` 里没有声明的工具，宿主拒绝并报错；声明了却在核心启动后 5 秒内没有注册，这个工具标为不可用，契约测试失败。
- 处理函数的返回值就是 `structuredContent`；需要给 Agent 的说明文字时，返回 `{ structuredContent, text }`。

## 8. 注册与发现

- **注册表**（`system/kernel.sqlite`）：安装或升级时写入接口、推导出的副作用上限、依赖关系，并建立全文索引；索引对象是工具全名、标题、描述和 `SKILL.md` 的摘要。语义检索在 P2 加入。
- 注册表不用启动应用，就能回答「有哪些工具」。应用核心运行时注册的工具列表，必须和 `interface.json` 一致，否则拒绝，并要求重新安装（防止「先骗到授权、再换掉工具」）。

## 9. 面向 Agent 的投影：元工具

Agent 常驻的只有三个元工具，外加数据层和系统服务的工具（[02](02-agent.md) 第 3.2 节）：

| 元工具 | 输入 | 输出 |
|---|---|---|
| `apps.search` | `{query, limit?}` | 匹配的工具列表：全名、标题、一句话描述、副作用上限 |
| `apps.describe` | `{app?, tool?}` | 应用摘要和 `SKILL.md`，或某个工具的完整输入输出 schema |
| `apps.call` | `{tool, args}` | 工具结果；结果过大时截断，并给出读取全文的句柄 |

**P1 不在会话中途动态注入应用工具。** 这样实现最简单，提示缓存最稳定。Agent SDK 虽然支持按需加载工具，但走 OpenRouter 时默认关闭（[tech-assessment.md](../research/tech-assessment.md) 第 6 节）；用元工具，行为不随服务商变化。等 S3（[11](11-engineering.md) 第 8 节）的数据出来，再决定要不要把高频工具升格成直接可见的工具。

**代码模式（P3）：** 批量操作时，宿主为每个应用生成带类型的存根（例如 `apps/tasks.ts`），让 Agent 写一段代码在 Workbench VM 里执行，存根经 vsock 回到宿主路由。

## 10. CLI 投影：`aos`（P1b）

```bash
aos apps list --json
aos tasks list --range week --json
aos notes extract-from-note --note-id n_42
aos events tail "note.*"             # 实时查看总线上的事件
aos call tasks.list '{"range":"today"}'   # 原样传 JSON 参数
```

- 实现：一个小的命令行程序，经 Unix socket 连到宿主，带宿主签发的会话令牌。权限、确认和审计与其他入口完全一样（[00](00-kernel.md) 第 4 节）。
- 参数从 `input` schema 投影：属性名转成 `--kebab-case`，枚举转成可选值，`$ref` 的对象只能用 JSON 传。
- 约定：加 `--json` 时标准输出只放 JSON，日志写到标准错误；退出码稳定（0 成功、1 失败、2 参数错误、3 被拒绝、4 需要确认）；支持 `--dry-run`；从不交互。保留位置参数，因为微软的实测表明「只接受 JSON 输入」会降低 Agent 的准确率。

## 11. MCP 投影

- **基线：MCP 2026-07-28**（当前版本，已核实）：无状态，没有 `initialize` 握手和会话，每个请求在 `_meta` 里自带版本和能力；服务端必须支持 `server/discover`；列表结果带 `ttlMs` 和 `cacheScope`；Tasks、MCP Apps 都是官方扩展。
- 用在三个地方：
  1. 原生进程和 VM 服务对宿主说 MCP（宿主是客户端）。
  2. 引擎里，元工具注册成 Agent SDK 的进程内 MCP 工具，再经 JSON-RPC 转给宿主（和 P0 的运行时工具同一个做法）。
  3. P4 起，可以把 AgentOS 的应用对外暴露成一个 MCP Server，供其他 MCP 客户端使用（需要单独授权）。
- 从 `interface.json` 到 MCP 工具定义的映射是机械的：`input` → `inputSchema`，`output` → `outputSchema`，`annotations` 里能对上的字段原样保留，副作用上限放进 `_meta`。

## 12. 不支持协议的应用（P3 起）

把下列能力包装成「低信任适配器」，副作用上限一律按 `irreversible` 处理：

| 适配器 | 能力 |
|---|---|
| AppleScript / JXA | 控制支持脚本的 Mac 应用（需要用户对每个目标应用授予自动化权限） |
| 快捷指令（`shortcuts run`） | 间接调用 App Intents |
| 辅助功能（AX）接口 | 读取或操作任意应用的界面（需要辅助功能权限） |
| 电脑操作（computer use） | 在 VM 或 macOS 来宾里用截图和鼠标键盘操作（[10](10-workbench-vm.md)） |

## 13. 契约测试与接口 lint

**契约测试**（`tests/contract.json`，由 Builder 生成）：

```jsonc
[ { "tool": "create", "input": { "title": "周会" }, "expect": "ok" },
  { "tool": "create", "input": {}, "expect": "invalid_args" },
  { "tool": "list", "input": { "range": "all" }, "expect": "ok",
    "assert": { "path": "$.items[0].title", "equals": "周会" } } ]
```

- 运行器只加载应用核心，在一份临时的数据副本上执行，不影响用户数据。
- Builder 每次修改后自己跑（运行时工具 `run_contract_tests`），安装和升级时宿主再跑一遍，失败就不切换版本。

**接口 lint**（安装时执行，不通过就拒绝）：

- 工具描述不能包含指令性内容（例如「忽略之前的指示」「调用 xxx 工具」），不能冒用其他应用的名字；防止工具投毒。
- 每个工具都要有 `output` schema 和至少一个用例。
- `interactive` 工具不能出现在 `subscribes` 的处理链里。
- 引用的共享 schema 必须存在，版本必须兼容。

## 14. 示例：P1 的笔记和待办

| 应用 | 工具 | 数据 | 订阅 |
|---|---|---|---|
| 笔记 `notes` | `notes.create`、`notes.update`、`notes.get`、`notes.search`、`notes.mergeInto` | `notes: rw` | — |
| 待办 `tasks` | `tasks.list`、`tasks.complete`、`tasks.extractFromNote` | `tasks: rw`、`notes: r` | `note.created`、`note.updated` |

1. 用户问「我这周有什么待办」：Agent 调用 `apps.search("待办")`，找到 `tasks.list`，再用 `apps.call` 调用它。
2. 用户在笔记里写了一行「TODO 周五前交报告」：笔记界面调用自己的 `notes.update` 写入，数据层发出 `note.updated`。
3. 待办核心收到事件，调用 `notes.get` 读正文，写入一条 `task`；数据层发出 `task.created`。
4. Agent 有一条订阅 `task.*` 的自动化：设置周五提醒，记入活动流。

## 15. 里程碑

| 阶段 | 内容 |
|---|---|
| P1a | `interface.json` 和 schema 子集；JS SDK（`tools.register`、`self.call`、`data`）；核心宿主上的调用路由；注册表和全文索引；元工具；契约测试运行器；接口 lint |
| P1b | `calls`（跨应用调用）和 `subscribes`；接口兼容检查；`aos` CLI |
| P2 | `longRunning` 任务；应用自定义事件（`emits`）；语义检索 |
| P3 | VM 服务接入；代码模式存根；遗留应用适配器；第三方 MCP 驱动；`ui` 视图（兼容 MCP Apps） |
| P4 | 原生应用接入（`--mcp`）；把 AgentOS 应用对外暴露为 MCP Server |

## 16. 风险与待定

- **生成接口的质量参差不齐**：靠共享 schema、lint、契约测试兜底，并用评测集持续度量「界面能完成的任务里，有多少能只通过接口完成」（[11](11-engineering.md) 第 4 节）。
- **无界面核心宿主的开销**：空闲回收、并发上限；S1 给出每个实例的内存数字后再定上限。
- 待定：命名空间冲突时是否允许用户「接管」一个命名空间（例如新笔记应用替代旧的，继承 `notes`）？建议允许，但要过接口兼容检查。
