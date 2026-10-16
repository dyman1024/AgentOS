# 06 事件总线（AgentOS Bus）

> 所属：[技术方案总览](README.md) ｜ 相关：[00 内核](00-kernel.md)、[05 协议](05-app-protocol.md)、[08 数据层](08-data.md)、[09 安全](09-security.md)、[02 Agent](02-agent.md)
>
> 依据：[system-architecture.md](../research/system-architecture.md) 第 4.5 节、[tech-assessment.md](../research/tech-assessment.md) 第 4.3 节和第 6 节

## 1. 定位

让任何应用、系统服务和 Agent，都能经 AgentOS 订阅其他地方发生的事。

- MCP 目前不覆盖应用之间的发布订阅：`subscriptions/listen` 只能通知「资源变了」；事件扩展还是工作组里的设计草图，没有被接纳，工作组章程也把通用发布订阅排除在外。所以 **AgentOS 自建总线**，语义按自己的需要定，对外时再做映射（第 11 节）。
- **宿主是唯一的消息中转**，应用之间没有直连通道。
- **大部分事件来自数据层**：「数据长存，应用可抛」意味着应用之间的协作大多围绕共享数据，所以数据层在写入后自动发出领域事件（[08](08-data.md) 第 5 节）。P1 只靠领域事件和系统事件，就能完成笔记和待办的联动。

## 2. 事件信封：CloudEvents 1.0（JSON）

```json
{
  "specversion": "1.0",
  "id": "01JB8Z…",
  "source": "agentos://data/notes",
  "type": "note.updated",
  "subject": "notes/n_42",
  "time": "2026-10-15T09:12:03Z",
  "datacontenttype": "application/json",
  "dataschema": "agentos:schema/event/note.updated@1",
  "labels": { "trust": "trusted", "taint": [], "sensitivity": "public" },
  "depth": 0,
  "runid": "run_01JB…",
  "traceparent": "00-4bf92f…-00f067…-01",
  "data": { "collection": "notes", "id": "n_42", "rev": 7, "changedFields": ["body"] }
}
```

| 字段 | 谁写 | 说明 |
|---|---|---|
| `source` | **宿主盖章** | 发出者：`agentos://data/<集合>`、`agentos://service/<名字>`、`agentos://app/<命名空间>`、`agentos://system`；应用无法伪造 |
| `id` | 宿主生成（ULID） | 用于去重 |
| `type` | 宿主或应用 | 应用自定义事件必须在 `interface.json` 的 `emits` 里声明过（P2） |
| `labels` | 宿主 | 继承自发出时的运行、实例或记录（[00](00-kernel.md) 第 6 节） |
| `depth` | 宿主 | 由事件触发的处理过程中再产生的事件，深度加一；超过上限就丢弃 |
| `runid`、`traceparent` | 宿主 | 串起一条完整的调用和事件链，用于审计和撤销 |

**事件要薄，读取要单独授权。** `data` 里只放 ID 和少量元数据，读取正文要另外调用一次（例如 `notes.get`、`data.get`、`mail.get`）。这样敏感数据不会在总线上扩散，每次读取也都经过授权和审计。

## 3. 事件类型

| 类别 | 例子 | 谁发出 | 阶段 |
|---|---|---|---|
| **领域事件** | `note.created`、`task.updated`、`expense.deleted` | 数据层，在写入提交后自动发出（[08](08-data.md) 第 5 节） | P1b |
| **系统事件** | `app.installed`、`app.updated`、`app.removed`、`automation.ran`、`run.completed`、`system.idle`、`system.wake`、`schedule.tick` | 宿主 | P1b |
| **服务事件** | `mail.received`（`trust=untrusted`）、`web.page.saved`、`media.playback.started` | 系统服务 | P2 / P3 |
| **应用自定义事件** | 和数据无关的事，例如 `pomodoro.finished` | 应用核心，`agentos.events.emit` | P2 |

- **命名**：`<域>.<过去式动词>` 或 `<域>.<名词>.<过去式动词>`。领域事件的「域」就是 schema 的类型名。
- **版本**：`dataschema` 带版本号；字段只增不改，不兼容的变化换一个新的事件类型。
- **最新值主题**（P2）：高频的状态类事件（例如播放进度）只保留最新一条，订阅时直接拿到当前值。

## 4. 接口

宿主内部的方法（应用经 SDK 调用，Agent 经自动化工具调用）：

| 方法 | 方向 | 参数 |
|---|---|---|
| `events/list` | 订阅方 → 宿主 | `{pattern?}` → 可订阅的事件类型及其 schema |
| `events/subscribe` | 订阅方 → 宿主 | `{pattern: "note.*", filter?: {…}, from?: "latest" \| "<cursor>"}` → `{subscriptionId, cursor}` |
| `events/deliver` | 宿主 → 订阅方 | `{subscriptionId, event, cursor}` |
| `events/ack` | 订阅方 → 宿主 | `{subscriptionId, cursor}` |
| `events/unsubscribe` | 订阅方 → 宿主 | `{subscriptionId}` |
| `events/emit` | 应用 → 宿主 | `{type, subject?, data}`，宿主补齐其余字段（P2） |

- **应用的订阅写在 `interface.json` 的 `subscribes` 里**，安装时由宿主创建，属于持久订阅；`agentos.events.subscribe(pattern, handler)` 只是给已声明的订阅绑定处理函数，handler 正常返回后 SDK 自动确认。
- **过滤条件**是简单的对象匹配，作用于 `data` 和信封字段，支持精确匹配、前缀（`"from": "*@company.com"`）和数值比较。复杂逻辑交给订阅方自己处理。

## 5. 投递语义

| 项 | 设计 |
|---|---|
| 可靠性 | **至少投递一次**；订阅方按 `id` 去重（SDK 自动做最近 1000 条的去重） |
| 顺序 | 同一来源的事件按顺序投递给同一个订阅；不同来源之间不保证 |
| 游标 | 由宿主为每个订阅保存；确认后前进 |
| 应用没在运行 | 宿主拉起应用的核心（[03](03-app-runtime.md) 第 4.3 节），从游标处投递 |
| 核心热重载 | 暂停投递，重载完成后从游标处补发（[03](03-app-runtime.md) 第 4.5 节） |
| 背压 | 每个订阅最多 16 条未确认的事件，超出就暂停投递 |
| 失败重试 | handler 抛错或超时（默认 30 秒）就重试，指数退避；同一条事件失败 5 次，移入死信并在活动流里告警，游标继续前进 |
| 保留 | 默认 30 天，可以按事件类型设置；游标指向的事件已被清理时，投递时标注 `truncated: true` |

## 6. 存储（SQLite，`system/kernel.sqlite`）

```sql
CREATE TABLE events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,    -- 全局单调递增，作为游标
  id TEXT UNIQUE, type TEXT, source TEXT, subject TEXT, time TEXT,
  labels TEXT, depth INTEGER, run_id TEXT, traceparent TEXT,
  data TEXT,                                -- JSON
  expires_at TEXT
);
CREATE INDEX events_type_seq ON events(type, seq);

CREATE TABLE subscriptions (
  id TEXT PRIMARY KEY,
  subscriber TEXT,                          -- app:<id>/core | automation:<id> | service:<name>
  pattern TEXT, filter TEXT, cursor INTEGER, grant_id TEXT, created_at TEXT, paused INTEGER DEFAULT 0
);

CREATE TABLE dead_letters (subscription_id TEXT, event_seq INTEGER, error TEXT, failed_at TEXT);
```

- 写入用追加模式，开启 WAL；过期事件由定时任务清理。
- 重建实现由数据层在同一事务直接追加领域事件（[08](08-data.md) 第 9 节），无需跨库 outbox 中转。

## 7. 订阅者

| 订阅者 | 怎样订阅 | 收到事件后 |
|---|---|---|
| 应用核心 | `interface.json` 的 `subscribes`，安装时授权 | 在核心宿主里执行 handler |
| Agent | 自动化（[02](02-agent.md) 第 3.4 节）；**Agent 可以订阅任意事件**（创始人决策） | 宿主创建一个运行来处理，事件不会塞进进行中的对话 |
| 系统服务 | 按需 | 服务内部处理 |

所有订阅都在设置里列出；Agent 创建的订阅（自动化）还会出现在活动流里，用户可以随时停用。

## 8. 权限与标签

- **应用**：订阅必须在 `subscribes` 里声明，并获得 `subscribe` 能力授权（[09](09-security.md) 第 5 节）。授权的范围是「事件类型通配加过滤条件」，可以撤销、可以设置过期。
- **Agent**：可以订阅任意事件，不需要逐项授权；但事件触发的运行按委托链计算权限（[00](00-kernel.md) 第 3.4 节）。
- 投递前，宿主会再次检查授权；授权被撤销时，相关订阅立即停止。
- 领域事件只投递给对这个集合有 `data.read` 授权的订阅方；`private` 事件同理。
- **标签随事件传播**：把带污点的事件投递给一个应用核心，这个核心实例就带上污点；事件触发的运行同样带上污点（[00](00-kernel.md) 第 6 节）。

## 9. 防风暴与防循环

- `depth` 上限默认是 5，超出就丢弃，并在活动流里告警。
- 每种事件类型有发出频率上限（默认每秒 50 条），每个订阅方也有处理频率上限。
- 循环检测：同一条 `traceparent` 链里，如果同样的「订阅方加事件类型」组合反复出现，就熔断这个订阅，并告警。
- 自动化还有每日次数和费用上限（[02](02-agent.md) 第 3.4 节）。

## 10. 可观测性

- `aos events tail "<pattern>"` 实时查看总线上的事件。
- 外壳的「总线带」在应用区底部滚动显示最近的事件，可信的为薄荷色，外部内容为琥珀色（[01](01-shell.md) 第 3.1 节）。
- 审计日志按 `traceparent` 串联「事件 → 调用 → 结果」整条链路（[00](00-kernel.md) 第 8 节）。

## 11. 与 MCP 事件草案的关系

MCP 的 Triggers & Events 工作组目前只有一份设计草图（2026-09 合入，未被接纳为 SEP）。它和本总线的主要差别：

| | MCP 事件草案 | AgentOS 总线 |
|---|---|---|
| 投递方式 | `events/poll`、`events/stream`（推送）；`events/subscribe` 只用于 webhook | 宿主主动投递给订阅方 |
| 游标 | 客户端保管 | 宿主为每个订阅保管 |
| 确认 | 没有 `ack` | 有 `ack`，支撑至少一次和背压 |
| 事件的定义 | 带参数的「事件源」 | 事件类型加过滤条件 |

结论：内部不追随草案；P4 对外暴露 AgentOS 的事件时，再按届时的标准写一层映射。

## 12. 示例

1. 用户在笔记界面写下「TODO 周五前交报告」，笔记核心调用 `data.put`，数据层发出 `note.updated`：`source=agentos://data/notes`、`labels.trust=trusted`（内容来自用户输入）、`depth=0`。
2. 待办应用持有 `subscribe: note.updated` 的授权，宿主拉起它的核心并投递。核心调用 `notes.get` 读正文，写入一条 `task`；这些调用继承同一个 `traceparent`。
3. 数据层发出 `task.created`，`depth=1`。Agent 有一条订阅 `task.*` 的自动化，宿主创建一个运行，设置周五提醒，记入活动流。

## 13. 里程碑

| 阶段 | 内容 |
|---|---|
| P1a | 领域事件写入 `outbox` 和总线日志（只记录，不投递），供 S 系列验证和调试 |
| P1b | 投递、确认、持久订阅、补发、背压、重试和死信；授权检查；depth 和频率上限；系统事件；Agent 的自动化订阅；`aos events tail`；总线带；笔记加待办演示 |
| P2 | 应用自定义事件；服务事件；最新值主题 |
| P3 | 邮件事件和污点；后台辅助进程里的投递（主窗口关闭后继续） |
| P4 | 对外映射到 MCP 事件标准 |

## 14. 风险

- 至少投递一次，就意味着订阅方必须做到幂等。SDK 会帮忙去重，但应用逻辑仍要考虑重复处理的情况；Builder 的模板要示范幂等写法。
- 邮件等事件长期保留，本身就是隐私负担。默认短保留期，正文不进总线。
- 订阅方一多，就会有常驻的耗电和内存成本。靠按需拉起核心、空闲回收和并发上限来控制。

## 固定计划的升级检查（2026-10-16）

自动化保存工具输入/输出契约、目标应用 ID 和当时的有效权限。每次领取运行前重查；契约或权限变化、工具变成交互式、调用权限撤销时暂停计划并写通知。用户恢复时重新确认变化后的计划。固定计划按事件或至少 60 秒的间隔运行；每计划每天最多 100 次，每次仅允许计划中的工具。主窗口关闭或后台接管时仍可执行。
