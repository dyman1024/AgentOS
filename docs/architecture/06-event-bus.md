# 06 事件总线（AgentOS Bus）

> 所属：[技术方案总览](README.md) ｜ 相关：[05 协议](05-app-protocol.md)、[08 数据层](08-data.md)、[09 安全](09-security.md)、[02 Agent](02-agent.md)
>
> 依据：[system-architecture.md](../research/system-architecture.md) 第 4.5 节

## 1. 定位

让任何应用、系统服务和 Agent，都能经 AgentOS 订阅其他应用发出的事件。

- MCP 目前不覆盖应用之间的发布订阅：`subscriptions/listen` 只能通知「资源变了」，事件扩展还只是草案，工作组的章程也把通用发布订阅排除在外。所以 **AgentOS 自建总线**。
- **形状对齐 MCP Triggers & Events 草案**，包括 `events/list`、`events/subscribe`、事件通知、游标和去重，将来可以和标准合流。
- **宿主是唯一的消息中转**，应用之间没有直连通道。

## 2. 事件信封：CloudEvents 1.0（JSON）

```json
{
  "specversion": "1.0",
  "id": "01JB8Z…",
  "source": "agentos://app/mail",
  "type": "mail.received",
  "subject": "msg/8812",
  "time": "2026-10-15T09:12:03Z",
  "datacontenttype": "application/json",
  "dataschema": "agentos:schema/mail.received@1",
  "trust": "untrusted",
  "taint": "email:alice@example.com",
  "sensitivity": "private",
  "depth": 0,
  "traceparent": "00-4bf92f…-00f067…-01",
  "data": { "messageId": "8812", "from": "alice@example.com", "subjectLine": "Q3 notes" }
}
```

| 字段 | 谁写 | 说明 |
|---|---|---|
| `source` | **宿主盖章** | 应用无法伪造来源 |
| `id` | 宿主生成（ULID） | 用于去重 |
| `type` | 应用 | 必须在应用的 `interface.emits` 里声明过 |
| `trust` / `taint` / `sensitivity` | 宿主根据来源判定，并与应用声明合并 | 见 [09](09-security.md) |
| `depth` | 宿主 | 由事件触发的事件会自增，超过上限就丢弃 |
| `traceparent` | 宿主 | 串起一条完整的调用和事件链，用于审计 |

**事件要薄，读取要单独授权。** `data` 里只放 ID 和少量元数据，读取正文要另外调用一次工具（例如 `mail.get`）。这样敏感数据不会在总线上扩散，每次读取也都会经过权限检查和审计。

## 3. 事件类型

- **命名**：`<域>.<名词>.<过去式动词>` 或 `<域>.<过去式动词>`，例如 `note.created`、`task.completed`、`mail.received`、`media.playback.started`。
- **声明**：写在应用清单的 `interface.emits` 里，包括 `payloadSchema`、`sensitivity` 和 `retainDays`。
- **版本**：`dataschema` 带版本号；字段只增不改，有不兼容的变化就换一个新的事件类型。
- **系统事件**：
  - `app.installed`、`app.updated`、`app.removed`
  - `data.<collection>.changed`（见 [08](08-data.md)）
  - `automation.ran`
  - `agent.task.completed`
  - `system.idle`、`system.wake`

## 4. 接口

| 方法 | 方向 | 参数 |
|---|---|---|
| `events/list` | 订阅方 → 宿主 | `{pattern?}` → 可订阅的事件类型及其 schema |
| `events/subscribe` | 订阅方 → 宿主 | `{pattern: "note.*", filter?: {…}, cursor?: "latest" \| "<cursor>", maxInFlight?: 16, durable?: true}` → `{subscriptionId, cursor}` |
| `notifications/events/event` | 宿主 → 订阅方 | `{subscriptionId, event, cursor}` |
| `events/ack` | 订阅方 → 宿主 | `{subscriptionId, cursor}` |
| `events/unsubscribe` | 订阅方 → 宿主 | `{subscriptionId}` |
| `events/emit` | 应用 → 宿主 | `{type, subject?, data}`（宿主补齐其余字段） |

JS SDK：`agentos.events.emit(type, data)`、`agentos.events.subscribe(pattern, handler, {filter, fromCursor})`，handler 处理完后由 SDK 自动确认。

**过滤条件**是一个简单的对象匹配，作用于 `data` 和信封字段，支持精确匹配、前缀（`"from": "*@company.com"`）和数值比较。复杂逻辑交给订阅方自己处理。

## 5. 投递语义

| 项 | 设计 |
|---|---|
| 可靠性 | **至少投递一次**；订阅方按 `id` 去重 |
| 顺序 | 同一来源的事件保持顺序；不同来源之间不保证 |
| 持久订阅 | `durable: true` 的订阅保存游标；应用关闭期间的事件，下次启动后从游标处补发 |
| 背压 | 每个订阅最多有 `maxInFlight` 条未确认的事件，超出就暂停投递 |
| 保留 | 按事件类型的 `retainDays` 保留；游标指向的事件已被清理时，返回 `truncated: true` |
| 最新值主题 | 高频的状态类事件（例如播放进度）只保留最新一条，订阅时直接拿到当前值 |
| 离线订阅方 | Agent 和系统服务一直在线；应用的持久订阅在应用启动时补齐，必要时也可以由宿主唤醒应用的无界面模式来处理 |

## 6. 存储（SQLite，`~/Library/Application Support/AgentOS/bus.sqlite`）

```sql
CREATE TABLE events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,    -- 全局单调递增，作为游标
  id TEXT UNIQUE, type TEXT, source TEXT, subject TEXT, time TEXT,
  trust TEXT, taint TEXT, sensitivity TEXT, depth INTEGER, traceparent TEXT,
  data TEXT,                                -- JSON
  expires_at TEXT
);
CREATE INDEX events_type_seq ON events(type, seq);

CREATE TABLE subscriptions (
  id TEXT PRIMARY KEY, subscriber TEXT,     -- app:<id> | agent | service:<name> | automation:<id>
  pattern TEXT, filter TEXT, durable INTEGER, cursor INTEGER,
  max_in_flight INTEGER, grant_id TEXT, created_at TEXT
);
```

- 写入用追加模式，并开启 WAL；过期事件由定时任务清理。
- 「最新值主题」用一张单独的表，按 `(type, subject)` 覆盖写入。

## 7. 权限

- **应用**：订阅必须在 `interface.subscribes` 里声明，并获得能力授权（[09](09-security.md)）。授权的范围是「事件类型通配加过滤条件」，可以撤销、可以设置过期。
- **Agent**：**可以订阅任意事件**（创始人决策），不需要逐项授权。所有订阅都会在活动流里列出，用户可以随时取消。
- **系统服务**：按需订阅。
- 投递前，宿主会再次检查授权；授权被撤销时，相关订阅立即停止。
- `sensitivity: private` 的事件只投递给有对应数据权限的订阅方。

## 8. 防风暴与防循环

- `depth` 上限默认是 5，超出就丢弃，并在活动流里告警。
- 每种事件类型有发送频率上限（默认每秒 50 条），每个订阅方也有处理频率上限。
- 循环检测：同一条 `traceparent` 链里，如果同样的「订阅方加事件类型」组合反复出现，就熔断。
- 自动化还有每日次数和费用上限（[02](02-agent.md)）。

## 9. 可观测性

- 用 `aos events tail "<pattern>"` 实时查看总线上的事件。
- 活动流会显示 Agent 和自动化处理过的事件。
- 审计日志按 `traceparent` 串联「事件 → 调用 → 结果」整条链路（[09](09-security.md)）。

## 10. 示例

1. 笔记应用调用 `agentos.events.emit("note.created", {id: "n_42", title: "周会"})`。
2. 宿主补上 `source=agentos://app/notes`、`trust=trusted`（内容来自用户输入）、`depth=0`，写入日志。
3. 待办应用持有 `subscribes: note.created` 的授权，收到事件后调用 `notes.get`，再调用 `tasks.create`；这两次调用继承同一个 `traceparent`。
4. 待办应用发出 `task.created`，`depth=1`。Agent 订阅了 `task.*`，于是把它记入活动流，并设置一个提醒。

## 11. 里程碑

| 阶段 | 内容 |
|---|---|
| P1 | SQLite 存储；emit、subscribe、ack；持久订阅和补发；授权检查；depth 上限和频率上限；Agent 订阅；`aos events tail`；笔记加待办演示 |
| P2 | 最新值主题；系统事件全集；在活动流里可视化 |
| P3 | 邮件事件、污点标记，以及先计划后执行的自动化 |
| P4 | 跟进 MCP 事件标准，提供对外适配 |

## 12. 风险

- 至少投递一次，就意味着订阅方必须做到幂等。SDK 会帮忙去重，但应用逻辑仍要考虑重复处理的情况。
- 邮件等事件长期保留，本身就是隐私负担。默认短保留期，正文不进总线。
- 订阅方一多，就会有常驻的耗电和内存成本。靠无界面模式按需唤醒，并设置并发上限来控制。
