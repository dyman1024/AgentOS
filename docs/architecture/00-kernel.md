# 00 内核：核心对象与单一检查点

> 所属：[技术方案总览](README.md) ｜ 被所有分册引用
>
> 依据：[tech-assessment.md](../research/tech-assessment.md) 第 2、3 节

## 1. 定位

内核是 AgentOS 里**唯一不可生成**的部分。本分册定义所有模块共用的四个核心对象，以及唯一的检查点；其他分册里的授权、审计、活动流、撤销、预算、污点，都以这里的定义为准。

为什么单独成册：这些概念原本散落在 [06](06-event-bus.md)、[08](08-data.md)、[09](09-security.md) 里，各自引用 `traceparent`，却没有统一的定义。P0 实测出的越界读取（[tech-assessment.md](../research/tech-assessment.md) 第 2 节）也说明，检查点必须覆盖运行时的所有入口，而不只是工具调用。

## 2. 内核的组成

| 组件 | 职责 | 详见 |
|---|---|---|
| 身份解析 | 为每一个进入宿主的请求确定主体，主体永远由宿主判定，不接受自报 | 本册第 4 节 |
| 授权表 | 保存能力授权和放行规则，计算一次请求的有效权限 | 本册第 3.2 节、[09](09-security.md) |
| 检查点 | 授权检查、出口策略、频率与深度限制、标签传播 | 本册第 5 节 |
| 运行管理 | 创建和结束运行，记账预算，维护运行的标签 | 本册第 3.3 节 |
| 副作用记录与审计 | 记录每一次写入和出口调用，支撑撤销和活动流；哈希链审计 | 本册第 7、8 节 |
| 注册表 | 应用、版本、接口、订阅的登记 | [04](04-app-package.md)、[05](05-app-protocol.md) |
| 路由与总线 | 工具调用路由、事件投递；二者都经过检查点 | [05](05-app-protocol.md)、[06](06-event-bus.md) |
| 密钥 | 钥匙串的唯一访问者 | [09](09-security.md) 第 10 节 |
| 恢复 | 回滚外壳和应用、安全模式启动 | [01](01-shell.md) |

重建代码落点：`Sources/AgentOSCore/`。内核是一个 Swift `actor`，存储用 系统 sqlite3（WAL），运行时、引擎客户端、数据层、总线、系统服务都只通过它的接口访问授权和记录。

## 3. 核心对象

### 3.1 主体（Principal）

主体是「谁在做这件事」。格式统一为字符串：

| 主体 | 格式 | 说明 |
|---|---|---|
| 用户 | `user` | 最终权威。来自外壳界面和本机终端的 `aos` CLI |
| Agent 运行 | `run:<runId>` | Agent 的每一次运行都是一个主体，权限按第 3.4 节计算 |
| 应用核心 | `app:<appId>/core` | 应用的无界面核心（[03](03-app-runtime.md) 第 4 节），持有应用的能力授权 |
| 应用界面 | `app:<appId>/ui` | 应用的界面；对共享数据**只读**，修改用户数据必须调用自己核心的工具 |
| 系统服务 | `service:<name>` | 例如 `service:mail`，可信 |
| 自动化 | `automation:<id>` | 自动化本身不执行操作；它触发的运行把它放进委托链 |
| VM 和原生进程 | `vm:<id>`、`app:<appId>/native` | 由宿主拉起时分配连接，连接即身份 |

同一个应用可能同时有多个实例（例如核心在后台处理事件，界面同时打开）。**标签作用在实例上**（第 6 节），所以每个实例有一个 `instanceId`，记录在请求的元数据里。

### 3.2 能力授权（Grant）

```jsonc
{ "id": "g_91",
  "holder": "app:3f2a…/core",
  "capability": "data.write",          // 能力类型，见下表
  "scope": { "collection": "tasks" },  // 范围
  "grantedBy": "user",                 // user，或按规则自动授予时为 policy:<规则>
  "grantedAt": "2026-10-15T09:12:03Z",
  "expiresAt": null,                   // 可设过期，例如「只在本次会话有效」
  "revokedAt": null }
```

| 能力类型 | 范围 | 例子 |
|---|---|---|
| `data.read` / `data.write` | 集合 | 待办应用读 `notes`、写 `tasks` |
| `files` | 用户授权的文件夹（security-scoped bookmark） | `~/Documents/Blog` |
| `net` | 域名 | `api.github.com` |
| `service` | 系统服务及其操作 | `ai.complete`、`mail.send`、`publish` |
| `subscribe` | 事件类型通配加过滤条件 | `note.created` |
| `call` | 其他应用的工具通配 | `notes.get` |
| `rule` | 出口放行规则（只能由用户创建） | 「`mail.send` 发给 `*@partner.com` 时直接放行」 |

Agent 不持有授权记录：Agent 的运行默认拥有全部能力（创始人决策：Agent ≈ root），但会被委托链收窄（第 3.4 节）。

### 3.3 运行（Run）

运行是**一次自主工作**：用户在对话里的一轮请求、一次自动化触发、一次应用发起的 `agent.ask`。授权的上限、预算、标签、审计链路都挂在运行上。

```jsonc
{ "id": "run_01JB…",
  "parentId": null,                        // 子运行（例如 Operator 把造应用交给 Builder）指向父运行
  "sessionId": "ses_…",                    // 所属会话；同一会话的运行共享标签
  "role": "operator | builder | automation | parser",
  "initiator": "user",                     // 发起主体
  "chain": ["user"],                       // 委托链，从最初的发起者到当前运行
  "trigger": { "type": "prompt | event | schedule | app", "ref": "…" },
  "labels": { "taint": [], "sensitivity": "public" },   // 第 6 节
  "budget": { "usd": 3.0, "deadline": "…" },
  "spentUsd": 0.42,
  "status": "running | done | failed | cancelled",
  "traceId": "4bf92f…",                    // 写进每次调用和事件的 traceparent
  "summary": "把 3 条笔记合并为「Q4 规划」" }
```

**一轮对话就是一个运行。** 用户发一条消息，宿主先创建运行，再把 `runId` 交给引擎（[02](02-agent.md) 第 3.6 节）。引擎的每一次工具调用都带着 `runId` 回到宿主。

**同一个会话里的运行共享标签。** 模型的上下文包含整段对话，上一轮读过的网页，下一轮仍在上下文里。所以标签累积在会话上：同一会话的新运行，一开始就继承会话已有的标签；开一个新对话（新会话）才从干净的状态开始。

### 3.4 有效权限

**一次请求的有效权限 = 委托链上每个主体权限的交集。**

| 场景 | 委托链 | 有效权限 |
|---|---|---|
| 用户在对话里让 Agent 办事 | `user → run` | 全部（Agent ≈ root），出口仍按权限模式把关 |
| 自动化被事件触发 | `创建者 → automation → run` | 自动化创建时固定的工具白名单 ∩ 创建者的权限 |
| 应用调用 `agent.ask` | `app:<id>/core → run` | **不超过该应用的能力授权**。防止应用借 Agent 越权（代理混淆） |
| 应用调用另一个应用的工具 | `app:A/core → app:B/core` | B 的工具以 B 的授权执行，但 A 必须持有 `call` 授权；B 执行期间沾上 A 的标签 |
| Agent 调用应用的工具 | `run → app:<id>/core` | 工具以应用的授权执行；结果的标签回到运行 |

### 3.5 副作用记录（Effect）

每一次写入或出口调用都留下一条记录，它是活动流、撤销和审计的共同来源。

```jsonc
{ "id": "eff_7c…",
  "runId": "run_01JB…",
  "principal": "app:3f2a…/core",          // 实际执行者
  "class": "write | fetch | external | irreversible",   // 副作用等级，见 09 第 3 节
  "action": "data.put",                   // 例如 data.put、app.rollback、grant.add、sink:mail.send
  "target": "notes/n_42",
  "undo": { "method": "data.restore", "args": { "collection": "notes", "id": "n_42", "rev": 6 } },
  "state": "applied | undone | failed",
  "confirmedBy": null,                    // 经用户确认时为 user，按规则放行时为 rule:<id>
  "at": "2026-10-15T10:40:12Z" }
```

`read` 不生成副作用记录，只在读取 `private` 数据和调用应用工具时写审计。

## 4. 身份解析：每个入口怎样确定主体

| 入口 | 主体怎样确定 | 现状 |
|---|---|---|
| WebView 消息桥 | 宿主维护「WebView → (appId, 实例, core/ui)」绑定表；只接受主 frame，且 origin 的 host 等于 appId | 已校验 frame 和 origin |
| `agentos://` scheme handler | 按**发起请求的 WebView** 查绑定表；URL 的 host 必须等于该 WebView 的 appId，否则 403 | 已校验（P1a 第一步，[03](03-app-runtime.md) 第 5 节）；P0 曾实测可越界（[tech-assessment.md](../research/tech-assessment.md) 第 2 节） |
| 导航 | 主 frame 只允许导航到本应用的 origin 和 `about:blank` | 已限制（同上） |
| 引擎 RPC | 引擎的请求必须带 `runId`，宿主核对它属于这个引擎进程的活动运行 | 只带 `appId` |
| `aos` CLI | 宿主签发的会话令牌（存在权限为 0600 的文件里），本机终端里的调用视为 `user` | 未实现 |
| 原生进程、VM 服务 | 宿主拉起时建立的 stdio 或 vsock 连接，连接即身份 | 未实现 |

## 5. 单一检查点

### 5.1 必须经过检查点的入口

工具调用（[05](05-app-protocol.md)）· 数据读写（[08](08-data.md)）· 事件的发送、订阅和投递（[06](06-event-bus.md)）· 出口服务（[07](07-system-services.md)）· scheme handler 和导航（[03](03-app-runtime.md)）· WebView 消息桥 · CLI socket · 引擎 RPC。

**不在各个运行时里分散实现**，这是 D-Bus 代理的教训（[09](09-security.md) 第 6.3 节）。

### 5.2 一次请求的处理顺序

```
请求进入
 1. 身份解析：主体、实例、运行；运行未结束、预算未用完
 2. 授权：动作是否在有效权限内（第 3.4 节）           → 否：denied（附原因）
 3. 限制：频率、事件深度、并发                         → 超出：denied 或排队
 4. 出口策略（只对出口）：副作用等级 × 权限模式 × 标签 × 放行规则
                                                     → 需要确认：交给外壳弹确认框，异步等待
 5. 执行
 6. 记录：审计；写入或出口调用生成副作用记录（含撤销方法）
 7. 标签传播：把结果的标签合并进调用方（运行或实例）
```

接口形状（Swift，示意）：

```swift
actor Kernel {
    func authorize(_ request: Request) async -> Decision   // allow / deny(reason) / confirm(prompt)
    func record(_ effect: Effect, for request: Request) async
    func propagate(_ labels: Labels, to principal: Principal) async
}
```

## 6. 信息流标签与传播

每个运行、应用实例和数据记录都带一组标签：

| 标签 | 取值 | 含义 |
|---|---|---|
| 可信度 `trust` | `trusted` / `untrusted` | 内容是否来自外部（网页、邮件、导入的文件、第三方 MCP 驱动） |
| 污点 `taint` | 来源列表，例如 `web:example.com`、`email:alice@partner.com` | 不可信内容的具体来源，用于确认框里的「来源链路」 |
| 机密性 `sensitivity` | `public` / `private` | 是否是私人数据（例如邮件索引、通讯录） |

**传播规则**（生成的 JS 代码内部怎样派生数据，宿主看不见，所以只做到这三层的粗粒度，这是有意的取舍）：

| 作用在 | 什么时候沾上 | 什么时候清除 |
|---|---|---|
| 运行（及其会话） | 任何带污点的工具结果、事件或数据记录进入这个运行 | 不清除；同一会话的后续运行继承，开新会话才清除 |
| 应用实例 | 实例收到带污点的数据（工具结果、事件、读到的记录） | 实例重载 |
| 数据记录 | 由带污点的运行或实例写入 | 只有用户能手动标为可信 |

机密性同理：读过 `private` 数据的运行或实例，记为接触过私人数据。标签怎样影响确认，见 [09](09-security.md) 第 4 节。

## 7. 撤销与重做

| 副作用 | 撤销方式 |
|---|---|
| 数据写入、删除 | 恢复到这次写入之前的版本。如果之后又有别的修改：只还原这次改过、之后没人再改的字段；有冲突的字段交给用户决定（[08](08-data.md) 第 6 节） |
| 应用升级、回滚 | 切换 `current` 版本，数据保留（[04](04-app-package.md) 第 6 节） |
| 授权变更 | 反向操作 |
| 创建或修改自动化 | 停用，或恢复到修改之前 |
| `external`（例如建日程、移到废纸篓） | 执行补偿操作（删除日程、从废纸篓还原） |
| `irreversible`（例如发信、发布） | **不可撤销**，活动流里明确标出；可以让 Agent 起草更正 |

撤销本身也是一次副作用，因此可以**重做**。按运行撤销时，按时间倒序逐条处理这个运行留下的副作用记录。

## 8. 审计

- 所有检查点的决定（允许、拒绝、确认结果）、副作用、授权变更、运行的开始和结束，都追加到审计日志。
- **哈希链**：每条记录包含上一条记录的哈希，可以发现篡改。
- 活动流是审计日志面向用户的视图：只显示 Agent 和自动化的运行，以及它们留下的副作用（[01](01-shell.md) 第 3.3 节）。
- 保留：默认 180 天；导出为 NDJSON。

## 9. 存储与目录

**宿主数据和应用文件分在两棵树里，scheme handler 只能看到应用那一棵，而且只能看到发起请求的那个应用。**

```
~/Library/Application Support/AgentOS/
├── apps/<appId>/              # 应用（见 04）；scheme handler 只服务本应用的 current/ 或开发中的 src/
└── system/                    # 宿主私有，永远不经过 scheme handler
    ├── kernel.sqlite          # 授权、运行、数据、历史、副作用、审计、注册表、事件与订阅
    ├── meta/<appId>/          # 对话记录等宿主侧元数据
    ├── appdata/<appId>/       # 原生应用的私有数据（P4）
    ├── agent/                 # Agent SDK 的会话目录（CLAUDE_CONFIG_DIR）
    └── logs/                  # 每次启动一个 JSONL 事件日志
```

```sql
-- kernel.sqlite（P1a）
CREATE TABLE grants  (id TEXT PRIMARY KEY, holder TEXT, capability TEXT, scope TEXT, granted_by TEXT,
                      granted_at TEXT, expires_at TEXT, revoked_at TEXT);
CREATE TABLE sessions (id TEXT PRIMARY KEY, role TEXT, app_id TEXT, labels TEXT, created_at TEXT);
CREATE TABLE runs    (id TEXT PRIMARY KEY, parent_id TEXT, session_id TEXT, role TEXT, initiator TEXT, chain TEXT, trigger TEXT,
                      labels TEXT, budget TEXT, spent_usd REAL, status TEXT, trace_id TEXT,
                      started_at TEXT, ended_at TEXT, summary TEXT);
CREATE TABLE effects (id TEXT PRIMARY KEY, run_id TEXT, principal TEXT, class TEXT, action TEXT, target TEXT,
                      undo TEXT, state TEXT, confirmed_by TEXT, at TEXT);
CREATE TABLE audit   (seq INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT, kind TEXT, principal TEXT, run_id TEXT,
                      detail TEXT, prev_hash TEXT, hash TEXT);
CREATE INDEX effects_run ON effects(run_id);
```

P0 的 `meta/`、`logs/`、`agent/` 在 P1a 迁移到 `system/` 下（迁移步骤见 [04](04-app-package.md) 第 4 节）。

## 10. 预算与限流

- **宿主记账，宿主执行。** 引擎在每条模型回复后上报用量（[02](02-agent.md) 第 3.6 节），宿主累加到运行；超出预算就取消运行。不依赖 Agent SDK 的 `maxBudgetUsd`，因为它是客户端估算，可能超支。
- 三层上限：单个运行（默认 3 美元）、每个自动化每天的次数和费用、全局每天的费用。应用调用 `ai.complete` 的费用计入该应用的每日配额。
- 并发：同时运行的完整 Agent 不超过 3 个，其余排队；交互式运行优先于自动化。

## 11. 里程碑

| 阶段 | 内容 |
|---|---|
| P1a | 主体与身份解析（含 scheme handler、导航、消息桥的绑定）；运行；副作用记录；审计；`data.*` 授权；检查点覆盖工具调用和数据；目录迁移到 `system/`；宿主记账 |
| P1b | `subscribe`、`call` 授权；放行规则；检查点覆盖事件和 CLI |
| P2 | 信息流标签的完整传播；出口策略（[09](09-security.md) 第 4 节）上线，是 P2 的发布门槛 |
| P3 | VM 和原生进程的连接身份；自动化的先计划后执行 |

## 12. 待定问题

- 审计日志放在 `kernel.sqlite` 里还是单独的追加文件？建议先放同一个库，量大了再拆。
- 应用实例的标签在「重载」时清除，是否足够？热重载频繁时，可能让污点意外丢失。建议核心实例的标签在 Builder 修改期间保留。

### 重建实现注记（2026-10-16）

数据写入、历史、副作用、领域事件与审计在单个事务提交。外部操作使用持久化 ticket，批准绑定参数、主体、运行与标签；执行前重新校验。HTTP 地址解析后固定连接公网 IP，重定向重新检查。计费调用先预留预算，按实际用量结算；进程中断后未结算预留按上限计入，避免重启重置预算。

费用结算补充：取消或崩溃时，未返回用量的预算预留按上限保守结算。之后收到实际费用可核对一次并调整差额，不重开结束运行；重复相同报告幂等，不同第二次报告拒绝。
