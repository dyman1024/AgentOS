# 08 个人数据层

> 所属：[技术方案总览](README.md) ｜ 相关：[05 协议](05-app-protocol.md)、[06 总线](06-event-bus.md)、[07 服务](07-system-services.md)、[09 安全](09-security.md)

## 1. 定位

**数据长存，应用可抛。** 个人数据，比如笔记、待办、文档、邮件索引、联系人、书签、媒体库、Agent 的记忆，都保存在系统级的数据层。应用只是数据之上的视图和工作流，可以随时重写、替换或分叉，数据不会丢。

具体目标：
- 多个应用共享同一份数据（例如写作应用和博客后台共用 `documents`）。
- Agent 能跨应用检索（例如「上周邮件里提到的那篇论文」）。
- 所有修改都有历史，可以撤销。
- 本地优先，数据属于用户，可以导出。

## 2. 两种存储

| 存储 | 放什么 | 位置 | 理由 |
|---|---|---|---|
| **集合**（结构化） | 笔记、待办、书签、联系人、邮件索引、媒体条目、记忆、用户档案 | SQLite：`~/Library/Application Support/AgentOS/data/store.sqlite` | 支持查询、索引、事务和历史 |
| **文件** | 文档和博客正文（Markdown）、附件、图片、视频 | 用户授权的文件夹（例如 `~/Documents/AgentOS/`） | 和其他工具互通（Obsidian、Git、Finder），用户看得见、带得走 |

文件可以在集合里登记一条索引记录（路径、标题、标签、摘要、向量），这样同样能被检索和订阅。

## 3. 集合与共享 schema

- 每个集合对应一个**共享领域 schema**（`agentos:schema/<type>@<ver>`），由 AgentOS 统一维护，生成的应用必须复用（[05](05-app-protocol.md)）。
- 应用确实需要扩展字段时，写到 `ext.<appId>.*` 命名空间里，不污染公共字段。

第一批 schema：

| 集合 | 核心字段 |
|---|---|
| `notes` | id、title、body（Markdown）、tags[]、links[]、createdAt、updatedAt |
| `tasks` | id、title、done、due、priority、source（例如 `note:n_42`）、tags[] |
| `documents` | id、path（文件引用）、title、status（draft / published）、publishedUrl、tags[] |
| `bookmarks` | id、url、title、excerpt、tags[]、savedFrom |
| `contacts` | id、name、emails[]、phones[]、notes |
| `mail` | id、account、folder、from、to[]、subject、date、snippet、flags（正文不进集合，按需通过 `mail.get` 读取） |
| `media` | id、path、kind（movie / episode / music）、title、year、duration、poster、progress |
| `memory` | id、kind（preference / fact / experience）、content、source、confidence |
| `profile` | 单条记录：name、language、tone、accounts… |

每条记录都自动带上系统字段：`_id`、`_rev`、`_createdBy`（`app:<id>` / `agent` / `user`）、`_updatedAt`、`_taint`、`_sensitivity`。

## 4. 接口

```js
const notes = agentos.data.collection('notes');
await notes.put({ title: '周会', body: '…' });                 // 新建或更新，返回带 _id 和 _rev 的记录
await notes.get(id);
await notes.query({ where: { tags: { has: 'work' } }, text: '季度规划', orderBy: '-updatedAt', limit: 20 });
await notes.delete(id);                                          // 软删除，可以恢复
const stop = notes.watch({ where: { tags: { has: 'todo' } } }, (change) => { … });   // 底层基于总线事件
```

- **查询**：字段条件、全文检索（SQLite FTS5）、排序和分页。P2 起支持语义检索（`semantic: "…"`，向量由 `ai.embed` 生成）。
- **变更事件**：每次写入都会发出 `data.<集合>.changed` 事件，内容是 `{id, op, rev}`，见 [06](06-event-bus.md)。
- **给 Agent 和 CLI 用的工具**：`data.query`、`data.get`、`data.put`、`data.history`、`data.restore`，命令行形式是 `aos data query notes --text … --json`。

## 5. 权限

- 应用按集合申请 `r` 或 `rw`（[04](04-app-package.md) 的 `permissions.data`），需要用户授权。
- Agent 可以读写全部集合（高权限）。
- `sensitivity: private` 的记录（例如邮件索引），只对持有该集合授权的主体可见。
- 文件只能访问用户授权的文件夹，通过 security-scoped bookmark 持久保存授权。

## 6. 历史、撤销与回滚

- **每次写入都记录一个版本**：`history` 表追加 `(_id, _rev, data, by, at, traceparent)`，删除只是做一个标记。
- **撤销**：活动流里的每一条，都能根据 `traceparent` 找到对应的写入，并逐条恢复（[01](01-shell.md)）。
- **时间点恢复**：可以把某个集合，或某个应用产生的全部写入，恢复到某个时间点。
- **文件**：授权文件夹里由 AgentOS 写入的文件，同样保留历史版本（P2 起，用 git 或快照）。
- 正因为有这套历史，Agent 才可以「大胆去做」（[09](09-security.md)）。

## 7. 污点传播

- 数据从不可信来源写入时（网页、邮件、用户导入的外部文件），记录上带 `_taint`。
- 由这类数据派生出来的数据（例如根据邮件生成的笔记）继承污点。
- 权限检查和 Agent 的确认策略会参考污点（[09](09-security.md)）。

## 8. 应用私有数据与共享数据的边界

| 数据 | 放哪里 |
|---|---|
| 应用自己的界面状态、缓存、游戏存档 | 应用私有存储：localStorage 或 IndexedDB（每个应用独立的 WebView 数据存储），原生应用放在 `apps/<id>/data/` |
| 对用户有长期价值、可能被其他应用或 Agent 使用的数据 | **共享集合** |

Builder 的系统提示会写明这条边界：「用户内容进入共享集合」。

## 9. 备份与导出

- 一键导出：全部集合导出成 JSON 或 NDJSON，加上文件和附件。
- 定期本地备份：SQLite 在线备份加上历史；P3 起可以把备份放到用户指定的位置（例如 iCloud Drive 文件夹）。
- 多设备同步暂不做，放在路线图之外。

## 10. 里程碑

| 阶段 | 内容 |
|---|---|
| P1 | SQLite 存储；`notes`、`tasks`、`documents` 三个集合的 schema；put、get、query（含全文检索）、delete、watch；变更事件；历史和撤销；Agent 和 CLI 工具 |
| P2 | 语义检索；`memory`、`profile`、`bookmarks`；文件索引和文件历史 |
| P3 | `mail`、`media`、`contacts`；污点传播全面落地；备份 |

## 11. 风险

- 共享 schema 设计得不好，会限制生成应用的表达力。所以允许 `ext.*` 扩展字段，并为 schema 做版本管理。
- 历史表会持续增长，需要设定保留策略和压缩。
- 数据层集中存放了所有个人数据，一旦泄露就是全部泄露。所以靠授权、审计和出站控制来守住，并考虑做加密存储（P3 评估）。
