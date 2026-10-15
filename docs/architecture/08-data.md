# 08 个人数据层

> 所属：[技术方案总览](README.md) ｜ 相关：[00 内核](00-kernel.md)、[05 协议](05-app-protocol.md)、[06 总线](06-event-bus.md)、[07 服务](07-system-services.md)、[09 安全](09-security.md)

## 1. 定位

**数据长存，应用可抛。** 个人数据，比如笔记、待办、记账、文档、邮件索引、联系人、书签、媒体库、Agent 的记忆，都保存在系统级的数据层。应用只是数据之上的视图和工作流，可以随时重写、替换或分叉，数据不会丢。

具体目标：

- 多个应用共享同一份数据（例如写作应用和博客后台共用 `documents`；两个不同风格的笔记应用共用 `notes`）。
- Agent 能跨应用检索（例如「上周邮件里提到的那篇论文」）。
- 所有修改都有历史，能精确撤销和重做。
- 本地优先，数据属于用户，可以导出。

## 2. 两种存储

| 存储 | 放什么 | 位置 | 理由 | 阶段 |
|---|---|---|---|---|
| **集合**（结构化） | 笔记、待办、记账、书签、联系人、邮件索引、媒体条目、记忆、用户档案 | SQLite：`system/data/store.sqlite` | 支持查询、索引、事务和历史 | P1a |
| **文件** | 文档和博客正文（Markdown）、附件、图片、视频 | 用户授权的文件夹（例如 `~/Documents/AgentOS/`） | 和其他工具互通（Obsidian、Git、Finder），用户看得见、带得走 | P2 |

文件在集合里登记一条索引记录（路径、标题、标签、摘要、向量），这样同样能被检索和订阅。

## 3. 集合与 schema

### 3.1 系统 schema

由 AgentOS 维护，随宿主发布，命名为 `agentos:schema/<type>@<major>`；对应的集合名是类型的复数。

| 集合 | 类型 | 核心字段 | 阶段 |
|---|---|---|---|
| `notes` | `note` | title、body（Markdown）、tags[]、links[] | P1a |
| `tasks` | `task` | title、done、due、priority、source（例如 `note:n_42`）、tags[] | P1a |
| `documents` | `document` | path（文件引用）、title、status（draft / published）、publishedUrl、tags[] | P2 |
| `bookmarks` | `bookmark` | url、title、excerpt、tags[]、savedFrom | P2 |
| `memory` | `memory` | kind（preference / fact / experience）、content、source、confidence | P2 |
| `profile` | `profile` | 单条记录：name、language、tone、accounts… | P2 |
| `contacts` | `contact` | name、emails[]、phones[]、notes | P3 |
| `mail` | `mail.summary` | account、folder、from、to[]、subject、date、snippet、flags（正文不进集合，按需通过 `mail.get` 读取） | P3 |
| `media` | `media.item` | path、kind（movie / episode / music）、title、year、duration、poster、progress | P3 |

### 3.2 用户 schema

生成的应用会遇到系统 schema 没覆盖的领域，例如记账本的「支出」。如果只允许系统 schema，这类数据只能塞进应用自己的 `localStorage`，应用一换就丢，违背「数据长存」。所以：

- Builder 可以在生成应用时**注册用户 schema**：`user:schema/<type>@<major>`，对应一个新的共享集合（例如 `expenses`）。
- 注册在安装时进行（[04](04-app-package.md) 第 6 节），要通过 lint：字段命名、必须有 `title` 或等价的显示字段、类型只用允许的子集（[05](05-app-protocol.md) 第 2.2 节）。
- 注册之后，它和系统 schema 一样，可以被其他应用引用和授权，也能被 Agent 检索。
- 命名冲突时（已经有人注册了 `expense`），Builder 必须复用已有的 schema，或者用扩展字段补充（第 3.3 节），不能另起一个同名类型。

### 3.3 扩展字段

应用需要在共享类型上加字段时，写到 `ext.<命名空间>.*` 下，例如 `ext.tasks.pomodoros`，不污染公共字段。其他应用可以读到，但不应依赖。

### 3.4 schema 演进

- 字段**只增不改**：新增可选字段是次版本；删除字段、改类型、新增必填字段是主版本，等于一个新类型（`note@2`）。
- 系统 schema 的主版本升级由宿主提供迁移；用户 schema 的主版本升级由 Builder 编写迁移脚本，安装时先备份受影响的集合再执行（[04](04-app-package.md) 第 6 节）。

### 3.5 孤儿集合

卸载应用不会删除数据。没有任何已安装应用声明使用的用户集合，在设置的「数据」页里列为「无人使用」，用户可以导出、删除，或者让 Builder 为它生成一个新的应用。

## 4. 接口

### 4.1 SDK

```js
const notes = agentos.data.collection('notes');
const n = await notes.put({ title: '周会', body: '…' });          // 新建：返回带 _id 和 _rev 的记录
await notes.put({ ...n, title: '周会纪要' }, { rev: n._rev });    // 更新：带上读到的版本；版本不符返回 conflict
await notes.get(id);
await notes.query({ where: { tags: { has: 'work' } }, text: '季度规划', orderBy: '-_updatedAt', limit: 20 });
await notes.delete(id);                                            // 软删除，可以恢复
```

- 核心可以读写（按授权）；**界面只读**，修改必须调用自己核心的工具（[03](03-app-runtime.md) 第 4.4 节）。
- 订阅变化用领域事件（第 5 节），不另设 `watch` 接口。

### 4.2 查询

| 能力 | 写法 | 实现 |
|---|---|---|
| 字段条件 | `where: { done: false, due: { lt: '2026-10-20' }, tags: { has: 'work' }, title: { prefix: '周' } }` | SQLite JSON 函数和表达式索引 |
| 全文检索 | `text: '季度规划'` | FTS5（中文用 `trigram` 分词器） |
| 排序和分页 | `orderBy: '-due'`、`limit`、`cursor` | — |
| 语义检索 | `semantic: '和强化学习有关的笔记'` | 向量由 `ai.embed` 生成（P2） |

复杂的关联查询不在数据层做，由调用方组合多次查询。

### 4.3 写入规则

- **共享集合没有归属应用**：任何持有 `data.write` 授权的主体都能写（[05](05-app-protocol.md) 第 3 节）。
- **乐观并发**：更新必须带读到的 `_rev`，不符就返回 `conflict`，由调用方重新读取后再写。不带 `_rev` 的更新只允许新建。
- **校验**：写入前按 schema 校验，不符合就返回 `invalid_args`。
- **事务**：一次 `put` 或 `delete` 是一个事务；批量写入用 `batch([...])`，要么全部成功，要么全部失败。

### 4.4 给 Agent 和 CLI 的工具

`data.query`、`data.get`、`data.put`、`data.delete`、`data.history`、`data.restore`、`data.schemas`（列出可用的集合和字段）。命令行形式：`aos data query notes --text 季度规划 --json`。

## 5. 领域事件

每次写入提交后，数据层自动发出领域事件，类型由 schema 的类型名派生（[06](06-event-bus.md) 第 3 节）：

| 写入 | 事件 | `data` |
|---|---|---|
| 新建 | `<type>.created`，例如 `note.created` | `{collection, id, rev}` |
| 更新 | `<type>.updated` | `{collection, id, rev, changedFields}` |
| 删除 | `<type>.deleted` | `{collection, id, rev}` |

- 事件只带 ID 和变化的字段名，不带内容；订阅方要读内容，需要另外查询，查询照常经过授权。
- 事件的标签继承写入时的标签（第 7 节）。
- 应用不需要、也不能自己发出这些事件，所以 P1 的应用间协作只靠数据层和领域事件就能完成；应用自定义事件放到 P2（[06](06-event-bus.md) 第 3 节）。

## 6. 历史、撤销与回滚

- **每次写入都记录一个版本**：`history` 表追加一行，包含写入前后的数据、操作者、所属的运行和副作用记录（第 9 节）。删除只是做标记。
- **撤销一次写入**（活动流里点「撤销」，[00](00-kernel.md) 第 7 节）：

  | 情况 | 处理 |
  |---|---|
  | 记录的当前版本就是这次写入产生的版本 | 恢复到写入前的版本 |
  | 之后又被修改过，但改的是别的字段 | 只还原这次写入改过的字段，之后的修改保留 |
  | 之后的修改和这次写入改了同一个字段 | 冲突：把两个值都展示给用户，由用户选择；Agent 发起的撤销则报告冲突，不自动覆盖 |

- **重做**：撤销本身也是一次写入，可以同样被撤销。
- **时间点恢复**：可以把某个集合，或者某个应用、某个运行产生的全部写入，恢复到某个时间点。
- **文件**（P2）：授权文件夹里由 AgentOS 写入的文件保留历史版本（每个授权文件夹一个内部 git 仓库，或 APFS 快照）。

## 7. 标签

- 每条记录带 `_labels`：可信度、污点来源、机密性（[00](00-kernel.md) 第 6 节）。
- 带污点的运行或应用实例写入的记录，自动带上污点；读到带污点的记录，读者（运行或实例）也随之带上污点。
- 机密性由集合决定默认值（`mail`、`contacts` 默认 `private`），写入方可以提高，不能降低。
- 用户可以在界面上把一条记录标为可信，这个操作记入审计。

## 8. 权限

- 应用按集合申请 `r` 或 `rw`（写在 `interface.json` 的 `data` 里），安装时转成能力授权（[09](09-security.md) 第 5 节）。
- 应用界面对共享数据只读；核心按授权读写。
- Agent 可以读写全部集合（高权限）；读写都会传播标签。
- `private` 集合的读取写入审计。
- 文件只能访问用户授权的文件夹，通过 security-scoped bookmark 持久保存授权。

## 9. 存储实现

```sql
-- system/data/store.sqlite（GRDB，WAL）
CREATE TABLE schemas  (type TEXT, major INTEGER, kind TEXT,          -- kind: system | user
                       collection TEXT, definition TEXT, registered_by TEXT, registered_at TEXT,
                       PRIMARY KEY (type, major));
CREATE TABLE records  (collection TEXT, id TEXT, rev INTEGER, data TEXT,   -- data 为 JSON
                       labels TEXT, created_by TEXT, updated_by TEXT, created_at TEXT, updated_at TEXT,
                       deleted INTEGER DEFAULT 0, PRIMARY KEY (collection, id));
CREATE TABLE history  (seq INTEGER PRIMARY KEY AUTOINCREMENT, collection TEXT, id TEXT, rev INTEGER,
                       op TEXT, before TEXT, after TEXT, by TEXT, run_id TEXT, effect_id TEXT, at TEXT);
CREATE TABLE outbox   (seq INTEGER PRIMARY KEY AUTOINCREMENT, event TEXT);   -- 待转入总线的领域事件
CREATE VIRTUAL TABLE records_fts USING fts5(collection, id, text, tokenize = 'trigram');
CREATE INDEX history_record ON history(collection, id, seq);
CREATE INDEX history_run ON history(run_id);
```

- 系统字段：`_id`、`_rev`、`_createdBy`（`app:<id>/core`、`run:<id>`、`user`）、`_updatedBy`、`_createdAt`、`_updatedAt`、`_labels`。
- 全文索引的 `text` 由 schema 里标记为可检索的字段拼接而成。
- 领域事件先写进 `outbox` 表，和数据写入在同一个事务里；宿主再把它转入总线日志（[06](06-event-bus.md) 第 6 节），转完删除。这样保证「写成功就一定有事件」。不直接跨库写 `bus.sqlite`，因为 WAL 模式下跨附加数据库的事务不是整体原子的。

## 10. 应用私有数据与共享数据的边界

| 数据 | 放哪里 |
|---|---|
| 界面状态、缓存、游戏存档、最高分 | 应用私有：`localStorage` 或 IndexedDB（每个应用独立的 WebView 数据存储）；原生应用放在 `system/appdata/<id>/` |
| 对用户有长期价值、可能被其他应用或 Agent 使用的数据 | **共享集合**（系统 schema 或用户 schema） |

Builder 的系统提示写明这条边界。回滚应用版本时两类数据都保留（[04](04-app-package.md) 第 6 节）。

## 11. 备份与导出

- 一键导出：全部集合导出成 NDJSON，加上 schema、文件和附件。
- 定期本地备份：SQLite 在线备份；P3 起可以放到用户指定的位置（例如 iCloud Drive 文件夹）。
- 多设备同步暂不做，放在路线图之外。

## 12. 里程碑

| 阶段 | 内容 |
|---|---|
| P1a | SQLite 存储；`notes`、`tasks` 系统 schema；用户 schema 注册；put（乐观并发）、get、query（含全文检索）、delete、batch；领域事件写入总线日志；历史、撤销、重做；Agent 和 CLI 工具；标签字段（先记录，P2 起参与把关） |
| P2 | 文件服务和 `documents`；语义检索；`memory`、`profile`、`bookmarks`；文件历史；标签传播全面参与出口策略 |
| P3 | `mail`、`media`、`contacts`；备份；加密存储评估 |

## 13. 风险与待定

- 共享 schema 设计得不好，会限制生成应用的表达力：靠用户 schema 和 `ext.*` 扩展字段缓解，并为 schema 做版本管理。
- 历史表会持续增长：默认保留 90 天加每条记录最近 50 个版本，超出的定期压缩。
- 数据层集中存放了所有个人数据，一旦泄露就是全部泄露：靠授权、审计和出口控制来守住；它永远不在 scheme handler 能访问的目录树里（[00](00-kernel.md) 第 9 节）；加密存储在 P3 评估。
- 待定：中文全文检索用 FTS5 的 `trigram` 分词器，少于 3 个字符的查询（例如「周会」）无法命中。是否需要额外的分词方案？P1a 先用 `trigram` 加 `LIKE` 兜底。
