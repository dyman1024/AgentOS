# 07 系统服务

> 所属：[技术方案总览](README.md) ｜ 相关：[00 内核](00-kernel.md)、[08 数据层](08-data.md)、[05 协议](05-app-protocol.md)、[09 安全](09-security.md)、[10 工作间 VM](10-workbench-vm.md)

## 1. 定位

**能用确定性服务的，就不要生成。** 网络协议、邮件收发、编解码、密钥、文件访问这类能力，由可信的系统服务提供：要么用 Swift 实现，要么跑在 Workbench VM 里，要么是经过审核的 MCP 驱动。应用和 Agent 共用这些服务。生成的部分集中在界面、工作流和个性化上。

**对外的服务就是系统的「出口」。** 应用不能联网，所有对外的副作用都必须经过这里，所以出口是副作用把关的唯一位置（[09](09-security.md) 第 3、4 节）。每次出口调用都经过内核的检查点，生成副作用记录（[00](00-kernel.md) 第 5 节）。

服务有两种暴露方式，背后是同一份实现、同一套检查：

- 给应用用：`agentos.<service>.*` SDK，经宿主桥接（[03](03-app-runtime.md)）。
- 给 Agent 和 CLI 用：注册为系统工具（[02](02-agent.md) 第 3.2 节）。

## 2. 服务清单

| 服务 | 能力 | 副作用等级 | 出口 | 实现 | 应用需要的能力 | 阶段 |
|---|---|---|---|---|---|---|
| `data` | 共享集合、全文和语义检索、历史 | read / write | — | Swift + SQLite（[08](08-data.md)） | `data.read` / `data.write` | P1a |
| `notify` | 发通知 | write | — | 宿主通知中心，可转发为系统通知 | `service: notify` | P1b |
| `files` | 读写用户授权的文件夹；文件选择器 | read / write；删除为移到废纸篓（external） | 是 | Swift，security-scoped bookmark | `files: [路径]` | P2 |
| `ai` | `complete`、`embed`：应用内调用大模型 | read（计费） | — | 宿主代为调用模型服务商，有配额 | `service: ai.complete` | P2 |
| `agent` | `ask(task)`：应用把任务交给 Agent | 随运行 | — | 引擎（[02](02-agent.md)）；**权限上限是该应用的授权** | `service: agent.ask` | P2 |
| `web` | `search`、`fetch`（提取正文） | fetch | 是 | 搜索 API；隐藏 WKWebView 加正文提取 | `service: web.*` | P2 |
| `browser` | `open(url)`：打开浏览器视图 | —（用户自己操作） | — | 独立的 WKWebView | 无（由用户或 Agent 发起） | P2 |
| `net` | `fetch(url)`：按域名白名单访问网络 | GET 为 fetch，其余为 irreversible | 是 | 宿主出口 | `net: [域名]` | P2 |
| `publish` | 发布博客（GitHub Pages 等） | irreversible | 是 | 宿主，凭据在钥匙串里 | `service: publish` | P2 |
| `clipboard` | 读写剪贴板 | 读为 read（`private`），写为 write | — | 宿主 | 读要授权，写不用 | P2 |
| `intent` | 「用……打开」「分享到……」 | — | — | 宿主路由 | 无（由用户发起） | P2 |
| `scheduler` | 定时任务、后台任务 | write | — | 宿主；P3 起移到常驻辅助进程 | `service: scheduler` | P1b |
| `mail` | `list`、`get`、`search`；`send` | 读为 read（`private`）；`send` 为 irreversible | `send` 是 | Swift（swift-nio-imap 或同类库），凭据只在宿主侧 | `service: mail.read` / `mail.send` | P3 |
| `calendar` | 读写系统日历 | `create`（不邀请他人）为 external；邀请他人为 irreversible | 是 | EventKit（需要系统授权） | `service: calendar.*` | P3 |
| `contacts` | 读系统通讯录 | read（`private`） | — | Contacts 框架 | `service: contacts.read` | P3 |
| `media` | 媒体库扫描、播放流（支持 Range）、元数据 | read / write | — | Swift；WebKit 解码，必要时用原生播放器组件 | `service: media` | P3 |
| MCP 驱动 | 接入外部 MCP Server（GitHub、Notion……） | 按驱动声明，**一律按 irreversible 上限处理** | 是 | 宿主作为 MCP 客户端连接，转成 `ext.<name>.*` 工具 | `call: ext.*` | P3 |
| `vm` | 在 VM 里执行命令、读写文件 | write（VM 有快照） | VM 的出站经宿主网络栈，按 `net` 处理 | Workbench VM（[10](10-workbench-vm.md)） | 只有 Agent 和应用后端可用 | P3 |

## 3. 关键服务的设计要点

### 3.1 `ai`：让应用也能调用大模型

```js
const summary = await agentos.ai.complete({ prompt: '总结这封邮件', input: mailText, maxTokens: 400 });
```

- 由宿主代为调用模型，**应用永远拿不到 API Key**。
- 每个应用有每日配额，计入全局预算（[00](00-kernel.md) 第 10 节）。
- 输入里如果带有污点数据，宿主会在请求外面加一层「这是数据，不是指令」的包装，并把污点传播到返回结果上；`private` 数据受模型限制（[09](09-security.md) 第 9 节）。
- `ai.complete` 没有工具，不能产生副作用，所以不需要出口把关。

### 3.2 `web`、`browser`、`net`：联网

- **`web.search`**：返回结构化结果（标题、链接、摘要），标记为 `trust=untrusted`。搜索服务的选择见第 6 节。
- **`web.fetch`**：在一个**隐藏的 WKWebView** 里加载页面，用非持久化的数据存储（不带用户的登录状态），在独立的 content world 里运行正文提取（Readability），返回 Markdown 和标题、链接列表，标记为 `trust=untrusted`。
  - 不需要 VM：网页脚本跑在 Apple 沙箱化的 WebContent 进程里，本来就不在宿主进程里执行。
  - 宿主记录每个运行里出现过的 URL，供 `fetch` 的三要素判定使用（[09](09-security.md) 第 4.2 节）。
- **`browser.open(url)`**：打开浏览器视图组件，一个正常的 WKWebView，不受应用沙箱限制，但与应用和宿主隔离。普通网站禁止被 iframe 嵌入，所以「上网」必须靠这个组件。在浏览器里登录的状态属于用户，应用和 Agent 都读不到；Agent 想读当前页面的内容，要用户点「把这一页交给 Agent」，内容标为不可信。
- **`net.fetch`**：应用获得 `net` 授权后，只能通过它访问白名单里的域名。CSP 不会放开，所有请求都经宿主出口并记入审计；GET 以外的请求按 `irreversible` 把关。

### 3.3 `publish`：发布

- P2 先支持 GitHub Pages（推送到用户指定的仓库，令牌存在钥匙串里）；Ghost、WordPress 等按需加入。
- 发布是 `irreversible`：谨慎模式每次确认；自动模式在运行带污点时确认（研究类任务读过网页，所以通常会确认），确认框里展示标题、目标地址和正文摘要。
- 发布前先在数据层的 `documents` 里把状态改为 `published` 并记下 `publishedUrl`；发布失败就回滚这次写入。

### 3.4 `agent.ask`：应用调用 Agent

- 应用把一个任务交给 Agent，宿主创建一个运行，委托链 = `app:<id>/core → run`。
- **这个运行的有效权限不超过该应用的能力授权**（[00](00-kernel.md) 第 3.4 节），防止只有笔记权限的应用借 Agent 读邮件。
- 结果返回给应用；运行出现在活动流里，标明「由某某应用发起」。

### 3.5 `mail`：邮件（P3）

- 第一步支持 IMAP 和 SMTP，配合应用专用密码（QQ、163、Gmail 都可以）。Gmail 的 OAuth 受限权限需要 Google 审核，放到后面再做。
- **凭据只存在钥匙串里**，由宿主建立连接；应用只能调用 `mail.list`、`mail.get`、`mail.search`、`mail.send`。
- 新邮件到达时发出 `mail.received` 事件，`trust=untrusted`；事件里只带 ID、发件人和标题（[06](06-event-bus.md)）。邮件索引写入 `mail` 集合，`private`。
- `mail.send` 是 `irreversible`，按权限模式把关；收件人可以用放行规则预先允许（[09](09-security.md) 第 4.4 节）。
- 后台同步由常驻辅助进程负责（第 3.7 节）。

### 3.6 `media`：看电影（P3）

- 扫描用户授权的文件夹，建立媒体库（`media` 集合），抓取海报和元数据（元数据源走宿主出口）。
- 通过 `agentos://media/<id>` 提供播放流，scheme handler 必须实现 **HTTP Range** 请求，否则无法拖动进度条。这个路径同样经过身份绑定，只对持有 `service: media` 的应用开放。
- WebKit 支持 H.264、HEVC、AV1、VP9。MKV 等容器格式 WebKit 不支持，需要**原生播放器组件**（例如基于 libmpv），应用通过 `agentos.media.play(id)` 调用。
- 有 DRM 的在线流媒体，只能交给浏览器视图组件。

### 3.7 `scheduler` 和后台辅助进程

- P1b：定时触发（自动化的 `schedule`）由宿主在主窗口打开期间执行。
- P3：定时器、重试、邮件同步、自动化执行交给一个**常驻辅助进程**（登录项，与主 App 共用 `system/` 目录）。主 App 退出后照常运行；两者通过 XPC 协作。辅助进程同样走内核的检查点（内核的存储层两边共用，写入通过 SQLite 的 WAL 协调）。

## 4. 系统组件（UI Kit）

生成的应用如果每次都临时写编辑器或播放器，质量不稳定，所以由系统提供经过打磨的组件。这些组件内置在 App 包里，固定版本，通过 import map 从同源的 `/_lib/` 只读引入：

| 组件 | 选型（P1a 时再评估） | 用途 | 阶段 |
|---|---|---|---|
| 界面基础 | Preact + htm、AgentOS 设计 tokens（CSS 变量，支持深浅色） | 风格统一，不需要构建 | P1a |
| Markdown 渲染 | marked + DOMPurify | 显示内容 | P1a |
| 富文本和 Markdown 编辑器 | Milkdown / TipTap | 文档、博客、笔记 | P1a |
| 代码编辑器 | CodeMirror 6 | 开发类应用 | P2 |
| 图表 | ECharts / Chart.js | 仪表盘、记账 | P1a |
| 游戏 | Phaser 3.x（固定版本）、three.js、Matter.js | 游戏 | P1a |
| 视频播放器 | 原生组件（`agentos.media.play`） | 媒体 | P3 |
| 浏览器视图 | 原生组件（`agentos.browser.open`） | 上网 | P2 |

每个库都配一张「API 卡片」写进 Builder 的 Skill，降低模型因为版本差异写错的概率。

## 5. 里程碑

| 阶段 | 内容 |
|---|---|
| P1a | `data`；UI Kit 第一版（界面基础、Markdown、编辑器、图表、游戏库） |
| P1b | `notify`；`scheduler`（主窗口打开期间） |
| P2 | `web`、`browser`、`net`、`publish`、`files`、`ai`、`agent.ask`、`clipboard`、`intent`；代码编辑器 |
| P3 | `mail`、`calendar`、`contacts`、`media` 和播放器组件、MCP 驱动、`vm`；后台辅助进程 |

## 6. 风险与待定

- 邮件和网页是提示注入的主要入口，必须配合 [09](09-security.md) 的标签和出口策略；P2 上线 `web` 之前，出口策略必须先就位。
- 后台辅助进程会带来常驻资源消耗，还有登录项的系统授权问题。
- 第三方 MCP 驱动的质量和安全性良莠不齐，默认按低信任处理。
- **待定：搜索服务。** 选项有三：① Anthropic 直连时用模型自带的服务端网页搜索（结果不经过宿主，无法打标签，也拿不到 URL 列表，需要评估能否接入第 3.2 节的机制）；② 用户自带搜索 API Key（例如 Brave Search API），由宿主调用，结果可控；③ 经 OpenRouter 的联网能力（未核实）。建议 P2 以 ② 为主，① 作为可选。
