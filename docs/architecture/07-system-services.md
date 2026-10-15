# 07 系统服务

> 所属：[技术方案总览](README.md) ｜ 相关：[08 数据层](08-data.md)、[05 协议](05-app-protocol.md)、[09 安全](09-security.md)、[10 工作间 VM](10-workbench-vm.md)

## 1. 定位

**能用确定性服务的，就不要生成。** 网络协议、邮件收发、编解码、密钥、文件访问这类能力，由可信的系统服务提供：要么用 Swift 实现，要么跑在 Workbench VM 里，要么是经过审核的 MCP 驱动。应用和 Agent 共用这些服务。生成的部分集中在界面、工作流和个性化上。

服务有两种暴露方式：
- 给应用用：`agentos.<service>.*` SDK，经宿主桥接（[03](03-app-runtime.md)）。
- 给 Agent 和 CLI 用：作为 MCP 工具注册在 `system.*` 命名空间下（[05](05-app-protocol.md)）。

两种方式背后是同一份实现，套用同一套权限检查（[09](09-security.md)）。

## 2. 服务清单

| 服务 | 能力 | 实现 | 应用需要的权限 | 阶段 |
|---|---|---|---|---|
| `data` | 共享集合、全文和语义检索、历史 | Swift + SQLite（[08](08-data.md)） | `data.<集合>: r / rw` | P1 |
| `files` | 读写用户授权的文件夹；文件选择器 | Swift，使用 security-scoped bookmark | `files: [路径]` | P1 |
| `notify` | 发通知 | 宿主通知中心，可转发为系统通知 | `services: notify` | P1 |
| `ai` | `complete`、`embed`；应用内调用大模型 | 宿主代为调用模型服务商，有配额 | `services: ai.complete` | P1 |
| `agent` | `ask(task)`：应用把任务交给 Agent | 引擎（[02](02-agent.md)） | `services: agent.ask` | P2 |
| `net` | `fetch(url)`：按应用的域名白名单访问网络 | 宿主出站代理 | `network: [域名]` | P2 |
| `web` | `search`、`fetch`（提取正文）、`browser.open` | 搜索 API 或模型自带的网页搜索；正文提取在 VM 里的无头浏览器中进行；浏览器视图组件 | `services: web.*` | P2 |
| `scheduler` | 定时任务、后台任务 | 宿主加常驻辅助进程（登录项） | `services: scheduler` | P2 |
| `intent` | 「用……打开」「分享到……」 | 宿主路由 | 无（由用户发起） | P2 |
| `clipboard` | 读写剪贴板 | 宿主 | 读要授权，写不用 | P2 |
| `publish` | 发布博客（GitHub Pages、Ghost、WordPress……） | 宿主，凭据在钥匙串里 | `services: publish` | P2 |
| `mail` | IMAP 收件、SMTP 发件、搜索、同步 | Swift（swift-nio-imap 或同类库），凭据只在宿主侧 | `services: mail.*` | P3 |
| `media` | 媒体库扫描、播放流（支持 Range）、元数据 | Swift；WebKit 负责解码，必要时用原生播放器组件 | `services: media` | P3 |
| `calendar` / `contacts` | 系统日历和通讯录 | EventKit / Contacts（需要系统授权） | `services: calendar.*` | P3 |
| `mcp` 驱动 | 接入外部 MCP Server（GitHub、Notion……） | 宿主作为 MCP 客户端连接，再转成 `ext.<name>.*` 工具 | `calls: ext.*` | P3 |
| `exec` / `fs` | 在 VM 里执行命令、读写文件 | Workbench VM（[10](10-workbench-vm.md)） | 只有 Agent 和应用后端可用 | P2 |

## 3. 关键服务的设计要点

### 3.1 `ai`：让应用也能调用大模型

```js
const summary = await agentos.ai.complete({ prompt: '总结这封邮件', input: mailText, maxTokens: 400 });
```

- 由宿主代为调用模型，**应用永远拿不到 API Key**。
- 每个应用有每日配额，计入全局预算。
- 输入里如果带有污点数据，宿主会在请求外面加一层「这是数据，不是指令」的包装，并把污点传播到返回结果上。

### 3.2 `net` 和 `web`：联网

- 应用默认完全不能联网（[03](03-app-runtime.md)）。获得 `network` 授权之后，也只能通过 `agentos.net.fetch` 访问白名单里的域名。CSP 不会放开，所有请求都经宿主代理并记入审计。
- `web.search` 返回结构化结果（标题、链接、摘要），标记为 `trust=untrusted`。
- `web.fetch` 在 VM 的无头浏览器里加载页面并提取正文，避免在宿主进程里执行任意网页脚本。
- `browser.open(url)` 打开**浏览器视图组件**：一个正常的 WKWebView，不受应用沙箱限制，但与应用和宿主隔离。因为普通网站禁止被 iframe 嵌入，所以「上网」必须靠这个组件。在浏览器里登录的状态属于用户，应用读不到。

### 3.3 `mail`：邮件

- 第一步支持 IMAP 和 SMTP，配合应用专用密码（QQ、163、Gmail 都可以）。Gmail 的 OAuth 受限权限需要 Google 审核，放到后面再做。
- **凭据只存在钥匙串里**，由宿主建立连接；应用只能调用 `mail.list`、`mail.get`、`mail.search`、`mail.send`。
- 新邮件到达时发出 `mail.received` 事件，`trust=untrusted`；事件里只带 ID 和标题（[06](06-event-bus.md)）。
- `mail.send` 属于 `external` 类操作，按 Agent 的权限模式决定是否确认（[09](09-security.md)）。
- 后台同步由常驻辅助进程负责，AgentOS 主窗口关闭后也能继续。

### 3.4 `media`：看电影

- 扫描用户授权的文件夹，建立媒体库（`media` 集合，见 [08](08-data.md)），抓取海报和元数据（元数据源走 `net` 白名单）。
- 通过 `agentos://media/<id>` 提供播放流，scheme handler 必须实现 **HTTP Range** 请求，否则无法拖动进度条。
- WebKit 支持 H.264、HEVC、AV1、VP9。MKV 等容器格式 WebKit 不支持，需要**原生播放器组件**（例如基于 libmpv），以系统组件的形式提供，应用通过 `agentos.media.play(id)` 调用。
- 有 DRM 的在线流媒体，只能交给浏览器视图组件。

### 3.5 `scheduler`：后台任务

- 定时器、重试和后台同步交给一个**常驻辅助进程**（作为登录项，与主 App 共用数据目录），用来接收事件、运行自动化、同步邮件。
- 主 App 退出后，辅助进程照常运行；主 App 打开时，两者通过 XPC 或 Unix socket 协作。

## 4. 系统组件（UI Kit）

生成的应用如果每次都临时写编辑器或播放器，质量不稳定，所以由系统提供经过打磨的组件。这些组件内置在本地，固定版本，通过 import map 从 `/_lib/` 引入：

| 组件 | 选型（P1 时再评估） | 用途 |
|---|---|---|
| 富文本和 Markdown 编辑器 | Milkdown / TipTap | 文档、博客、笔记 |
| 代码编辑器 | CodeMirror 6 | 开发类应用 |
| Markdown 渲染 | marked + DOMPurify | 显示内容 |
| 图表 | ECharts / Chart.js | 仪表盘 |
| 界面基础 | Preact + htm、AgentOS 设计 tokens（CSS 变量，支持深浅色） | 风格统一，不需要构建 |
| 游戏 | Phaser 3.x（固定版本）、three.js、Matter.js | 游戏 |
| 视频播放器 | 原生组件（`agentos.media.play`） | 媒体 |
| 浏览器视图 | 原生组件（`agentos.browser.open`） | 上网 |

每个库都配一张「API 卡片」写进 Builder 的 Skill，降低模型因为版本差异写错的概率。

## 5. 里程碑

| 阶段 | 内容 |
|---|---|
| P1 | data、files、notify、ai；UI Kit 第一版（编辑器、Markdown、界面基础） |
| P2 | net、web 和浏览器组件、scheduler 和辅助进程、intent、clipboard、publish、agent.ask；VM 的 exec 和 fs |
| P3 | mail、media 和播放器组件、日历和通讯录、MCP 驱动 |

## 6. 风险

- 邮件和网页是提示注入的主要入口，必须配合 [09](09-security.md) 的污点和隔离机制。
- 后台辅助进程会带来常驻资源消耗，还有登录项的系统授权问题。
- 第三方 MCP 驱动的质量和安全性良莠不齐，默认按低信任处理。
