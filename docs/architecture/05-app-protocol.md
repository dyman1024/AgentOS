# 05 应用协议（MCP / CLI）

> 所属：[技术方案总览](README.md) ｜ 相关：[06 事件总线](06-event-bus.md)、[09 安全](09-security.md)、[02 Agent](02-agent.md)、[03 运行时](03-app-runtime.md)
>
> 依据：[system-architecture.md](../research/system-architecture.md) 第 4 节

## 1. 定位

**这是 AgentOS 最核心的差异化：所有应用天然支持同一套协议。**

- **每个应用都是一个 MCP Server**，对外提供工具，可以读取它的资源，也能参与事件总线。
- **宿主是唯一的 MCP 客户端，也是唯一的中转**，负责路由、权限检查、盖上来源标记和审计。应用之间不能直接通信，Agent 也不能直连应用。
- **接口和应用一起诞生**：Builder 每生成或修改一个应用，都要同时交付 `interface`、`SKILL.md` 和契约测试。传统系统要给存量应用「补」Agent 接口，所以覆盖率很低；AgentOS 能做到 100% 覆盖。
- **CLI 是同一套接口的另一种投影**，例如 `aos <app> <tool> --json`，方便脚本、终端，以及 Agent 的代码模式调用。

```
Agent ──MCP──▶ ┌──────── 宿主路由 ────────┐ ──▶ 应用（WebView / 原生进程 / VM / 远端）
aos CLI ──────▶│ 授权 · 确认 · 审计 · 污点  │
应用 A ───────▶└──────────┬───────────────┘
                           └── 事件总线（见 06）
```

## 2. MCP 基线与适配

- **基线版本：MCP 2026-07-28。** 这一版是无状态的：去掉了 `initialize` 握手和会话，每个请求在 `_meta` 里自带版本和能力，新增 `server/discover`；工具支持 `inputSchema`、`outputSchema` 和 `structuredContent`；Tasks 和 MCP Apps 以扩展的形式提供。
- **请求无状态，宿主可以直接代理转发。** 每转发一次，宿主都会在 `_meta` 里写上调用方身份、委托链、污点标记和 `traceparent`。
- **MCP 缺少的部分**：
  - 订阅只能通知「资源变了」，不能携带内容（`subscriptions/listen`）。
  - 自定义事件还只是草案。

  所以应用之间的发布订阅由 AgentOS 自建，见 [06](06-event-bus.md)。
- **内部协议保持「MCP 形状」，外面包一层适配器。** 锁定版本，MCP 再次大改时只需要改适配层。

## 3. 接口声明（清单中的 `interface` 块）

```jsonc
"interface": {
  "id": "mail",                               // 命名空间，由宿主分配并保证唯一
  "tools": "interface/tools.json",            // 静态工具列表快照，用哈希锁定
  "resources": ["mail://message/{id}"],       // 可读取的资源（URI 模板）
  "emits": [                                  // 发出的事件（见 06）
    { "type": "mail.received", "payloadSchema": "interface/schemas/mail.received.json",
      "sensitivity": "private", "retainDays": 30 }
  ],
  "subscribes": ["calendar.event.*"],          // 申请订阅，需要授权
  "calls": ["contacts.lookup"],                // 申请调用其他应用，需要授权
  "headless": ["mail.search", "mail.get"],     // 不打开界面也能调用
  "skill": "SKILL.md",                         // 给 Agent 看的使用说明
  "cli": true,                                 // 是否投影到 aos CLI
  "ui": ["ui://mail/compose"]                  // 可以嵌入其他界面的视图（兼容 MCP Apps）
}
```

`interface/tools.json` 里的每个工具形如：

```jsonc
{ "name": "mail.search",
  "description": "按条件搜索邮件，返回摘要列表（不含正文）",
  "inputSchema":  { "type": "object", "properties": { "query": {"type": "string"}, "limit": {"type": "integer", "default": 20} }, "required": ["query"] },
  "outputSchema": { "type": "object", "properties": { "items": { "type": "array", "items": { "$ref": "agentos:schema/mail.summary@1" } } } },
  "annotations":  { "idempotent": true } }
```

**规则：**

| 规则 | 说明 |
|---|---|
| 命名 | 工具名是 `<interface.id>.<动词或名词>`，例如 `notes.create`、`mail.search`，全局唯一 |
| 副作用等级（effects） | `read`、`write`、`external`（对外发送）、`destructive`（不可逆删除）。**由宿主在审核时判定**，应用自己声明的 annotations 只作参考 |
| 快照锁定 | 注册表不用启动应用，就能根据快照为它的工具建索引。应用运行时报出的工具列表，哈希必须和快照一致，否则拒绝并要求重新授权，防止「先骗到授权、再换掉工具」 |
| 共享领域 schema | 数据类型优先引用 `agentos:schema/<type>@<ver>`（见 [08](08-data.md)），例如 `note`、`task`、`document`、`mail.summary`、`contact`、`media.item`、`bookmark` |
| 结构化结果 | 工具返回 `structuredContent`，必须符合 `outputSchema`；同时附一段简短文本，方便 Agent 阅读 |
| 错误 | 输入错误返回 `isError` 和可读的原因；`external` 或 `destructive` 类操作被拒绝时，返回 `denied` 并说明原因 |

## 4. 各类运行时的传输方式

所有运行时的 JSON-RPC 内容都一样，只是承载方式不同：

| 运行时 | 应用 → 宿主 | 宿主 → 应用 |
|---|---|---|
| Web（JS） | `WKScriptMessageHandlerWithReply`，沿用 frame 和 origin 校验 | 在独立的 content world 里执行 `callAsyncJavaScript`；`headless` 工具由隐藏的 WebView 提供 |
| 原生进程 | 用 `--mcp` 启动，通过 stdio 传输（宿主拉起进程并保持长连接） | 同左 |
| VM 服务 | 通过 virtio-vsock 传 stdio 或 HTTP，不在网络上暴露端口 | 同左 |
| 远端 | Streamable HTTP + OAuth | 同左 |

### 4.1 JS 应用的 SDK（P1，注入到 shim 里）

```js
// 注册工具：handler 返回值必须符合 outputSchema
agentos.tools.register('notes.create', {
  description: '新建一条笔记',
  inputSchema: { type: 'object', properties: { title: {type:'string'}, body: {type:'string'} }, required: ['title'] },
  outputSchema: { $ref: 'agentos:schema/note@1' },
}, async ({ title, body }) => { const note = await store.add({ title, body }); return note; });

// 调用其他应用（需要 interface.calls 里声明过，并获得授权）
const items = await agentos.call('mail.search', { query: 'from:alice', limit: 5 });

// 发出和订阅事件（见 06）
agentos.events.emit('note.created', { id: note.id });
agentos.events.subscribe('mail.received', (ev) => { /* … */ });
```

- Builder 写出来的 `register` 调用，必须和 `interface/tools.json` 一致。打包时会做静态校验，契约测试会做运行时校验。
- 应用页面加载完成，就算「在线」；应用没打开时，宿主用隐藏的 WebView 执行它的 `headless` 工具。

## 5. 注册与发现

- **注册表**：安装或升级时，读取 `interface` 和工具快照写入注册表，并建立全文和语义索引。索引对象是工具名、描述和 Skill 的元数据。
- **`server/discover`**：宿主可以向在线的应用确认工具列表，并比对哈希。
- **Agent 如何发现工具**（见 [02](02-agent.md)）：
  1. 常驻的只有元工具，包括 `apps.search(query)`、`apps.describe(id)`、`apps.call(tool, args)`、`events.list`、`events.subscribe`，以及每个应用 Skill 的元数据（约 100 token）。
  2. 应用工具全部延迟加载，通过搜索按需载入。
  3. 批量操作走代码模式：宿主为每个应用生成带类型的存根，例如 `apps/mail.ts`。

## 6. CLI 投影：`aos`

```bash
aos apps list --json
aos mail search --query "from:alice Q3" --limit 5 --json
aos notes create --title "周会" --body-file notes.md
aos events tail "note.*"            # 实时查看总线上的事件
aos call mail.get '{"id":"8812"}'    # 原样传 JSON 参数
```

- 实现：一个小的命令行程序，经 Unix socket 连到宿主，带会话令牌。权限、确认和审计和 MCP 调用完全一样。
- 约定：
  - 标准输出只放 JSON（加 `--json` 时），日志写到标准错误。
  - 退出码稳定：0 成功、1 失败、2 参数错误、3 被拒绝、4 需要确认。
  - 支持 `--dry-run`，从不交互。
  - 保留位置参数，因为微软的实测表明「只接受 JSON 输入」会降低 Agent 的准确率。
- 使用者：用户的终端、Workbench VM 里的脚本（通过 vsock 转发），以及 Agent 的代码模式。

## 7. 不支持协议的应用

用适配器把下列能力包装成「低信任 MCP Server」，所有副作用都需要确认：

| 适配器 | 能力 |
|---|---|
| AppleScript / JXA | 控制支持脚本的 Mac 应用（需要用户对每个目标应用授予自动化权限） |
| 快捷指令（`shortcuts run`） | 间接调用 App Intents |
| 辅助功能（AX）接口 | 读取或操作任意应用的界面（需要辅助功能权限） |
| 电脑操作（computer use） | 在 VM 或 macOS 来宾里用截图和鼠标键盘操作（[10](10-workbench-vm.md)） |

## 8. 契约测试

- Builder 为每个工具生成测试用例：合法输入应当符合 `outputSchema`；非法输入应当返回 `isError`。
- 安装和升级时自动运行（[04](04-app-package.md)），失败就阻止安装。
- 共享 schema 有 lint：字段命名、必填字段、版本兼容。

## 9. 示例：P1 演示

| 应用 | 工具 | 事件 |
|---|---|---|
| 笔记 `notes` | `notes.create`、`notes.get`、`notes.search`、`notes.update` | 发出 `note.created`、`note.updated` |
| 待办 `tasks` | `tasks.create`、`tasks.list`、`tasks.complete` | 发出 `task.created`；订阅 `note.created`，把正文里的 TODO 转成待办 |

整个演示的流程：

1. Agent 用 `apps.search("待办")` 找到 `tasks.list`，调用它回答「我今天有什么待办」。
2. 用户在笔记里写了一行「TODO 周五前交报告」，笔记应用发出 `note.created`。
3. 待办应用收到事件，调用 `notes.get` 读到正文，再调用自己的 `tasks.create`。
4. Agent 订阅了 `task.created`，在活动流里记一笔，周五提醒用户。

## 10. 里程碑

| 阶段 | 内容 |
|---|---|
| P1 | 接口声明、注册表和快照锁定、JS SDK、宿主路由、元工具、`aos` CLI、契约测试、共享 schema 第一版、笔记加待办演示 |
| P2 | 代码模式存根；VM 服务接入（vsock）；兼容 MCP Apps 界面 |
| P3 | 原生应用接入（`--mcp` stdio）；遗留应用适配器 |
| P4 | 远端应用（HTTP 加 OAuth）；运行第三方 MCP 应用和 MCP 驱动 |

## 11. 风险

- MCP 版本变动大：锁定版本，加适配层。
- 生成的 schema 质量参差不齐：靠共享 schema、lint 和契约测试兜底。
- 隐藏 WebView 执行无界面工具的开销：空闲回收，并设置并发上限。
