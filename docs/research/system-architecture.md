# Personal AgentOS 系统技术方案

> 2026-10-15 ｜ 环境：M5 Pro，48 GB 内存，macOS 26.5.1，Xcode 26.6
>
> 标记：**[实测]** 在本机测得（代码见 [vm-experiments/](vm-experiments/)、[native-experiments/](native-experiments/)）；**[未核实]** 公开资料无法确认。
>
> 前置文档：[愿景](../vision/personal-agentos.md) · [第一轮调研](architecture-research.md) · [Web 与 Native 对比](native-vs-web.md)

---

## 0. 结论速览

本方案针对创始人提出的三个设想：

| 设想 | 结论 |
|---|---|
| **① 像 Parallels Desktop 那样，是一个跑在 Mac 上的独立系统，应用由 Agent 生成** | **体验上像 Parallels，实现上像 WSL2 / ChromeOS Crostini。** 用户看到的是一个完整独立的系统，有自己的桌面、应用、数据和回滚。底层分三层：宿主负责所有界面渲染和可信内核；一台用户看不见的 Linux 微虚拟机做 Agent 的「工作间」，承载工具链、后台服务和不可信的原生代码；单次任务用的不可信代码放进临时微虚拟机。**不把用户应用放进虚拟机。** 原因有两个：一是 Virtualization.framework 不给 Linux 来宾 3D GPU；二是要把来宾应用逐个窗口融入 Mac 桌面，等于自己再造一个 WSLg，工作量以月计。 |
| **② 三类应用产物：JS 动态应用、本地生成机器码的应用包、云端构建后下载安装** | **三类都可行，统一成一种包格式 `.agentpkg`，走同一条安装与校验流程。** A 类（JS）是默认；B 类（本地编译）只需 Command Line Tools，编译不到 1 秒，应用在独立沙箱进程里运行；C 类（云端构建）用**用户自己的** GitHub Actions 构建，下载后由 AgentOS 验证并在本地重签名。另有两条红线：不能用 AgentOS 的开发者证书给用户的应用签名；不自建 Mac 构建农场。 |
| **③ 所有应用天然支持一套 MCP/CLI 协议，并能通过 AgentOS 与全局其他应用通讯和订阅** | **这是 AgentOS 最核心的差异化，而且在生成式系统里能做到 100% 覆盖。** 传统系统（Windows、Android、Apple）都在给存量应用「补」Agent 接口，而 AgentOS 的应用由 Agent 生成，**接口和应用一起诞生**。方案如下：每个应用都是一个 MCP Server，宿主是唯一的 MCP 客户端和唯一的消息中转，负责路由和权限把关；在 MCP 之上自建一条事件总线（CloudEvents 格式，形状对齐 MCP 正在制定的事件草案），用能力授权控制谁能订阅谁、谁能调用谁；CLI 是同一套接口的另一种投影。 |

---

## 1. 整体架构

```
┌──────────────────────────── AgentOS.app（宿主，可信内核）────────────────────────────┐
│ 外壳：桌面 / 启动台 / 窗口 / 通知中心（可生成）           对话：Agent 主入口              │
│ ┌──────────── 应用宿主 ─────────────┐  ┌──────────── 系统服务 ─────────────────────┐   │
│ │ A：JS 应用（沙箱 WebView）           │  │ 数据层 · 文件 · 邮件 · 媒体 · 搜索与浏览器    │   │
│ │ B/C：原生应用（Seatbelt 沙箱进程）   │  │ AI · 通知 · 后台任务 · 出站代理（域名白名单） │   │
│ │ W：WASM 模块（计算或无界面工具）     │  └──────────────────────────────────────────┘   │
│ └───────────────────────────────────┘                                                │
│ ┌──────────────── AgentOS Bus ─────────────────────────────────────────────────────┐ │
│ │ MCP Router（宿主是唯一客户端）· Event Broker（CloudEvents，SQLite 追加日志）       │ │
│ │ 能力授权 · 宿主绘制的确认框 · 污点标记 · 哈希链审计日志                             │ │
│ └──────────────────────────────────────────────────────────────────────────────────┘ │
│ 内核：包管理（.agentpkg 校验 / 安装 / 回滚）· 密钥 · 权限 · 版本快照 · 恢复模式          │
│ Agent 引擎（sidecar）：Builder / Operator · 元工具 + 按需加载工具                        │
└───────────────┬──────────────────────────────────────────────────┬───────────────────┘
                │ vsock / virtiofs（只共享授权目录）                 │ HTTPS
┌───────────────▼──────────────────────────────┐   ┌──────────────▼──────────────────────┐
│ Workbench VM（Linux，基于 Apple Containerization）│   │ 模型服务商（Anthropic / OpenRouter）  │
│ 工具链 · 应用后端 · 定时任务 · 无头浏览器         │   │ 云端构建（用户自己的 GitHub Actions） │
│ 临时微虚拟机：运行不可信代码、单次任务            │   └─────────────────────────────────────┘
└──────────────────────────────────────────────┘
```

---

## 2. 底座：为什么是「体验像 Parallels，实现像 WSL2」

### 2.1 实测数据

| 项目 | 结果 |
|---|---|
| 极简 Linux VM（2 vCPU，Virtualization.framework，直接引导内核） | `start()` 返回耗时 72–87 ms，**用户态就绪 230–300 ms** [实测] |
| VM 空闲时占用宿主内存 | 配置 512 MB 时占 115 MB，配置 4 GB 时占 254 MB [实测] |
| 保存和恢复整机状态 | 512 MB 的 VM：保存 235 ms，恢复 172 ms；4 GB 的 VM：保存 675 ms，恢复 618 ms；状态文件 22–46 MB [实测] |
| `docker run --rm alpine true` | 中位数 211 ms；`docker exec` 42 ms [实测] |
| 来宾释放的内存是否还给宿主 | **不还**。Docker 的 VM 实际占用约 3.5 GB，但宿主侧被占住了整整 24 GB [实测]，原因是 Virtualization.framework 只部分支持内存气球 |
| Linux 来宾的图形能力 | Virtualization.framework 只提供 2D 帧缓冲，**没有 3D 加速**；macOS 来宾有半虚拟化的 Metal |
| macOS 来宾 | 每台 Mac 最多同时 2 个，许可只允许开发、测试或个人非商业用途，App Store 登录不可用 |

### 2.2 选项对比

| 底座 | 隔离强度 | 启动 | 图形 | 应用窗口能否融入 Mac 桌面 | 能否嵌入我们的 App / 许可 | 结论 |
|---|---|---|---|---|---|---|
| 宿主 WebView（现在） | WebKit 独立进程 + CSP | 46 ms | Metal 加速的 WebGL/WebGPU | 原生 | 系统框架 | **所有用户界面都放这里** |
| 宿主 Seatbelt 进程 | 系统沙箱 | 0.1–0.6 s | 完整 Metal | 独立窗口 | 需要 CLT | B/C 类原生应用 |
| **Apple Containerization**（1.5.0，Apache-2.0） | 每个容器一个 VM | 亚秒级（官方说法） | 无 | 无 | **可以作为 Swift 库嵌进我们的进程** | **Workbench VM 和临时微虚拟机** |
| 直接用 Virtualization.framework 跑 Linux VM | 虚拟机级 | 0.23–0.30 s [实测] | 仅 2D | 只能整屏显示 | 公开 API | 作为 Containerization 的底层 |
| macOS 来宾 VM | 虚拟机级 | 慢 | 半虚拟化 Metal | 不支持 Coherence（ARM 上的 macOS 来宾） | 最多 2 个，许可受限 | 只用于「安全地操作真实 Mac 应用」 |
| Parallels Desktop | 虚拟机级 | — | 有 | Coherence | **不能嵌入**，SDK 已弃用 | 不采用 |
| OrbStack / Docker Desktop | 共享 VM | 0.21 s | 无 | 无 | 闭源，无 SDK | 不采用 |
| libkrun / krunkit | 微虚拟机 | — | 只有 Vulkan 计算，**不能绘图** | 无 | 开源（具体许可未核实） | 备选：在 VM 里做 GPU 计算 |

### 2.3 为什么不把用户应用放进 VM

| VM 带来的好处 | VM 带来的代价 |
|---|---|
| 虚拟机级隔离，远强于 Seatbelt | **Linux 来宾没有 3D**：游戏、WebGPU、视频都只能留在宿主 |
| Agent 拿到 root 和完整的 Linux 环境（apt、pip、npm、gcc、Rust、ffmpeg、无头 Chromium），**用户不用装 Xcode** | **窗口融入**：要让来宾应用一个窗口对应一个 Mac 窗口，就得自己做 WSLg（来宾合成器、逐窗口缓冲、输入、剪贴板、拖放），工作量以月计 |
| 整机快照和回滚在 1 秒内完成 [实测] | **观感**：GTK/Qt 外观，无障碍差，中文输入法需要来宾侧的 fcitx 或额外桥接 |
| 和云端微虚拟机（E2B、Firecracker）共用 OCI 镜像，C 类产物天然一致 | **内存**：来宾占用的内存不还给宿主，必须设上限并定期回收 |
| 和主流「Agent 电脑」的做法一致（E2B、Manus、Devin、ChatGPT agent 都是 Linux VM 加像素流） | 这些 Agent 电脑**都不给用户提供原生的单应用窗口** |

**结论：** 用户应用（界面）一律在宿主渲染，VM 只做「看不见的工作间」。用户感知到的「独立系统」由三样东西构成：AgentOS 自己的外壳、数据、回滚和隔离，而不是靠一个整屏的来宾桌面。如果以后确实需要运行 Linux 图形应用，就在 WebView 面板里用 Xvfb + noVNC 显示，或者给它开一个整屏窗口；逐窗口融入的方案推迟。

### 2.4 Workbench VM 设计要点

- **实现**：用 Apple Containerization 的 Swift 包，直接跑在我们自己的进程里，不依赖 Docker、OrbStack 或 Parallels。一台常驻 VM，设 4–8 GB 上限，挂一块持久磁盘存放工具链和缓存。不可信的单次任务放进临时微虚拟机，用完即弃。
- **通信**：宿主和 VM 之间走 vsock 上的 gRPC 或 MCP，不在网络上暴露任何端口。文件只通过 virtiofs 共享已授权的目录。
- **网络**：每台 VM 用 macOS 26 新增的 vmnet 独立 NAT，所有出站流量经过宿主的出站代理，套用各应用的域名白名单。
- **快照**：用 `saveMachineState` 实现秒级挂起和恢复。磁盘回滚目前靠 APFS 克隆；最低系统版本升到 macOS 27 后，改用 DiskImageKit 的分层写时复制磁盘。
- **对 Agent 暴露为** `agentos.exec`、`agentos.fs`、`agentos.service.*` 等工具。

---

## 3. 应用产物：三类应用，一种包格式

### 3.1 对比

| | **A：JS 动态应用** | **B：本地编译（生成机器码）** | **C：云端构建** | W：WASM 模块 | O：OCI 容器 |
|---|---|---|---|---|---|
| 在哪里构建，要多久 | 不需要构建；重新加载约 5 ms | 用户的 Mac：热编译 0.4–0.7 s，首次 SwiftPM 构建约 30 s，首次启动另有约 0.5 s 安全扫描 [实测] | 云端 Mac：排队加构建加传输，以分钟计 | 本地或云端，秒级 | 本地或云端 |
| 用户需要装什么 | 无 | **Command Line Tools，1.9 GB**（SDK 不允许随 App 分发） | 无 | 无，运行时内嵌 | 无，Containerization 内嵌 |
| 隔离方式 | WebKit 进程 + CSP | 独立进程 + Seatbelt 或 App Sandbox（ad-hoc 签名可用 [实测]） | 同 B | 基于能力的强隔离 | 微虚拟机，最强 |
| 性能和图形 | JIT，约 60 fps，WebGL/WebGPU | 原生，Metal，120 Hz | 同 B | 接近原生，但没有图形标准 | 原生 Linux，没有 Mac 图形 |
| 系统能力 | 只能通过 `agentos.*` | 所有框架，受授权约束 | 同 B | 只能用宿主提供的接口 | 在 VM 内使用 |
| 适合做什么 | **默认，绝大多数应用** | Metal 重度渲染、120 Hz、深度系统集成、导出成独立 `.app` | 依赖很重的项目、非 Mac 目标平台、不愿装 CLT 的用户、需要分享的可复现构建 | 计算模块、无界面工具 | 应用后端、数据库、爬虫、Python/Node 服务 |
| 怎么提供 MCP/CLI 接口 | JS 在宿主桥上注册工具 | 用 `--mcp` 参数以 stdio 方式运行 | 同 B | 导出 WIT 接口，由宿主映射成 MCP | 在 VM 里以 stdio 运行，经 vsock 连到宿主 |

### 3.2 统一包格式 `.agentpkg`

```jsonc
{ "schema": "agentos.app/1",
  "id": "app.agentos.u7f3.mail", "version": "1.4.0+27",
  "runtime":   { "kind": "web | macos-native | wasm-component | oci", "entry": "…", "arch": ["arm64"] },
  "permissions": { "network": [...], "data": {...}, "services": [...], "files": [...] },
  "interface": { /* 见第 4.3 节：MCP 工具、事件、订阅、调用、副作用分级、Skill、CLI、UI */ },
  "source":    { "digest": "sha256:…", "recipe": "swiftpm | swiftc | cargo-component | containerfile" },
  "artifacts": [{ "path": "payload/Mail.app", "digest": "sha256:…" }],
  "provenance":{ "builder": "local | gha:<user>/<repo>/…@<sha>", "attestation": "…sigstore.json" },
  "signature": { "alg": "ed25519", "keyId": "device:…", "sig": "…" },
  "update":    { "previous": "1.3.2+26", "dataSchema": 3 } }
```

包里**始终附带源码**，所以任何版本都能在本地重新构建、继续迭代。

**安装流程（所有类型共用）：**
1. 验签。
2. 校验每个产物的摘要。
3. C 类额外检查构建证明（attestation），核对构建者身份，并确认源码摘要与 Agent 提交的一致。
4. 向用户展示权限变化。
5. 安装到 `apps/<id>/<version>/`。
6. 原生应用按 `permissions` 生成 Seatbelt 规则，并在本地重新 ad-hoc 签名。**包里自带的授权一律忽略。**
7. 原子切换 `current` 符号链接，保留前 N 个版本，回滚就是把链接切回去。

### 3.3 Apple 政策红线

- **不能用 AgentOS 的 Developer ID 给用户的应用签名。** 开发者计划许可协议 §5.1 禁止用自己的证书签第三方应用。万一某个被提示注入的应用触发证书吊销，会连带 AgentOS 本体一起无法运行。
- **不自建托管的 Xcode 构建服务。** Xcode 许可只允许内部使用，禁止通过网络供多台机器同时使用；云端 Mac 还有 24 小时的最短租期。
- **C 类采用「自带构建账号」模式。** 在用户自己的 GitHub 仓库里用 `macos-26` runner 构建，约 $0.062/分钟，每次构建约 $0.06–0.5。费用和许可义务都归用户，和「自带 API Key」的思路一致。只有用户要把应用导出分享，且有自己的 Developer ID 时，才在本地做公证。
- **AgentOS 自己下载的文件不带隔离标记**，所以不会经过 Gatekeeper 检查，**AgentOS 本身就成了信任关口**，第 3.2 节的校验必须做严。用户从网页或邮件里下载的文件则必须保留隔离标记。

---

## 4. AgentOS 应用协议与总线（核心差异化）

### 4.1 现状：MCP 能做什么，缺什么

- **当前版本是 2026-07-28。** 这一版改成了无状态：去掉了 `initialize` 握手和会话，每个请求自带版本和能力信息，新增 `server/discover`。Tasks 移到了扩展里；采样、日志、roots 被标记为弃用。
- **「系统控制应用」这一侧已经够用。** 工具带有输入和输出 schema 以及结构化结果；MCP Apps（界面扩展）已经是官方扩展。
- **「应用之间发布订阅」这一侧缺失。**
  - `resources/subscribe` 已被移除，取而代之的 `subscriptions/listen` 只能通知「资源变了」，不能携带内容，也不支持自定义事件和回放。
  - 应用自定义事件还只是 Triggers & Events 工作组的草案，包括 `events/list` 和事件内容 schema、游标、去重，草案里明确写着「事件内容是不可信数据」。
  - 该工作组的章程**明确把通用发布订阅排除在外**。

**所以：** 系统调用应用用 MCP；应用之间的总线由 AgentOS 自建，形状对齐 MCP 的事件草案，以便将来合流。

### 4.2 系统厂商的先例

| 先例 | 2026 年状态 | 借鉴什么 |
|---|---|---|
| Windows 设备端 MCP 注册表与 Agent 连接器 | 预览中 | 清单里内置静态的工具列表快照；MCP Server 在独立的 Agent 账户里运行；授权分「始终、每次询问、从不」三档。**它的缺陷要避开**：文件授权对所有 Server 一视同仁，而不是按 Server 分别授权 |
| Android AppFunctions | 实验性 | 编译期生成 schema，由系统建索引；Google 称之为「设备端的 MCP 工具」 |
| Apple App Intents | 已发布（WWDC26 增加了长任务、可取消意图和 App Schemas） | 带类型的实体，以及共享的领域 schema。系统级 MCP 的代码出现在 26.1 测试版里，是否正式发布**未核实** |
| D-Bus | 成熟 | 信号加匹配规则、自省、按服务名设访问策略。**但过滤要集中在一个中心代理里做**，xdg-dbus-proxy 至今仍不断出现绕过类 CVE |
| Fuchsia / Plan 9 | — | 没有显式路由的能力，应用就访问不到；每个应用只看得到自己的命名空间 |
| NATS JetStream / MQTT 5 | 成熟 | 带通配符的允许和拒绝列表、持久消费者、背压控制、按序号回放 |
| CloudEvents 1.0 | CNCF 毕业项目 | 事件信封格式 |
| A2A 1.0 | Linux 基金会 | 只用于远端 Agent 之间，设备内不需要 |

### 4.3 应用如何声明接口（清单中的 `interface` 块）

```jsonc
"interface": {
  "id": "mail",                                   // 命名空间由宿主分配，保证唯一
  "tools": "interface/tools.json",                // 静态工具列表快照，用哈希锁定
  "emits": [{ "type": "mail.received", "payloadSchema": "schemas/received.json",
              "sensitivity": "private", "retainDays": 30 }],
  "subscribes": ["calendar.event.*"],             // 申请订阅，需要授权
  "calls": ["contacts.lookup"],                   // 申请调用其他应用，需要授权
  "effects": { "mail.search": "read", "mail.send": "external", "mail.delete": "destructive" },
  "headless": ["mail.search", "mail.get"],        // 不打开界面也能调用
  "skill": "SKILL.md", "cli": true, "ui": ["ui://mail/compose"]
}
```

- **工具列表锁定**：注册表不用启动应用就能索引它的工具。应用运行时报出的工具列表，如果和清单里快照的哈希不一致，就拒绝并请用户重新授权，防止「先骗授权、再换工具」。
- **副作用分级由宿主决定**：`effects` 由宿主在审核时判定，不采信应用自己的声明。
- **共享领域 schema**：邮件、笔记、联系人、文档、媒体等数据类型由 AgentOS 统一定义，生成的应用必须复用，再加 lint 检查。这一点借鉴自 App Schemas。
- **Builder 必须一起交付**：每生成或修改一个应用，都要同时生成接口、`SKILL.md` 和接口的契约测试。

### 4.4 各类运行时的传输方式

各运行时的 JSON-RPC 内容完全相同，只是承载方式不同：

| 运行时 | 应用 → 宿主 | 宿主 → 应用 |
|---|---|---|
| JS（WebView） | `WKScriptMessageHandlerWithReply`，沿用现有的 frame 和 origin 校验 | 在独立的 content world 里执行 `callAsyncJavaScript`。`headless` 工具由一个隐藏的 WebView 提供 |
| 原生进程（B/C） | 以 stdio 方式运行 MCP，进程由宿主在沙箱里拉起 | 同左 |
| VM 里的服务（O） | stdio 或 HTTP，经 virtio-vsock 传输，不暴露网络端口 | 同左 |
| 云端或远端 | Streamable HTTP 加 OAuth | 同左 |

### 4.5 总线

- **信封**：CloudEvents 1.0。`source` 字段（例如 `agentos://app/mail`）由宿主盖章，应用无法伪造。扩展属性包括 `trust`（可信度）、`taint`（污点来源）、`depth`（事件触发深度）和 `traceparent`（链路追踪）。
- **方法**：对齐 MCP 事件草案，包括 `events/list`、`events/subscribe{类型通配, 过滤条件, 游标}`、`notifications/events/event` 和 `events/ack`。
- **投递语义**：
  - 每种事件类型一份 SQLite 追加日志，每个订阅者一个持久游标。
  - 至少投递一次，按事件 id 去重；用 `maxInFlight` 做背压。
  - 应用关闭期间的事件，下次启动时从游标处补发。
  - 高频状态用「只保留最新值」的主题。
- **事件要薄，读取要单独授权**：事件只携带 ID 和少量元数据，读取完整内容要另走一次需要权限的工具调用。这样可以减少敏感数据在总线上扩散。

### 4.6 权限

- `subscribes` 和 `calls` 都是能力授权，可以限定范围（类型通配加过滤条件）、随时撤销、设置过期时间，由内核统一保存。
- 一次调用的实际权限 = 调用方应用的授权 ∩ 发起这件事的主体（用户或 Agent）的权限。
- `external`（对外发送）和 `destructive`（删除）类操作，一律弹出**宿主绘制的确认框**并展示参数，应用界面无法伪造。

### 4.7 Agent 如何面对几百个应用的工具

1. **常驻**：只加载少量元工具，例如 `apps.search`、`apps.describe`、`apps.call`、`events.subscribe`、`automation.create`，再加上各应用 Skill 的元数据（每个约 100 token）。
2. **按需加载**：应用工具设为延迟加载，通过工具搜索按需加载。Anthropic 公布的数据是 token 减少约 85%，准确率从 49% 提升到 74%。
3. **批量操作用代码模式**：为每个应用生成带类型的接口存根（如 `apps/mail.ts`），让 Agent 写代码批量调用。Anthropic 公布的数据是从约 150k token 降到约 2k。
4. **CLI 是同一套 schema 的另一种投影**：形如 `aos mail search --query … --json`，经 Unix socket 连到宿主，权限和审计照样生效。约定：标准输出只放 JSON、日志走标准错误、退出码稳定、支持 `--dry-run`、从不交互。

### 4.8 不支持协议的应用怎么办

把 AppleScript/JXA、`shortcuts run`、辅助功能 API、在 VM 里执行的电脑操作（computer use）分别包装成「低信任适配器」形式的 MCP Server，所有副作用都需要确认。

### 4.9 安全：总线天然构成「致命三要素」

总线上同时存在私人数据、不可信内容和对外发送的渠道，这正是提示注入最危险的组合。对策：

- **信息流控制**：每个事件和工具结果都标记可信度和机密性（参照微软 FIDES）。只要 Agent 的上下文里混入了 `untrusted` 内容，任何对外发送或删除操作都必须由宿主确认。
- **事件触发的自动化采用「先计划后执行」**：用户创建自动化时，就固定可用的工具和收件人；事件内容交给一个**没有任何工具**的隔离模型解析成结构化字段（Dual-LLM / CaMeL 模式），这样即使事件内容里藏了指令，也没有工具可以执行。
- **防工具投毒**：工具定义用哈希锁定；Builder 生成的工具描述要过 lint，防止工具投毒和跨服务冒名。
- **防事件风暴**：限制事件触发深度（`depth`），并按事件类型限流。
- **审计**：所有调用、事件和授权都写进按 `traceparent` 串联的哈希链审计日志。

### 4.10 Agent 的权限模型（创始人决策：给 Agent 极大权限）

**Agent 是这个 OS 里的最高权限主体（相当于 root）。** 它可以：
- 主动订阅任何事件，调用任何应用的任何工具，读写全部个人数据；
- 创建和修改自动化，安装和修改应用，在 Workbench VM 里执行任意命令。

默认不逐条请求授权。**应用仍然遵循最小权限**，因为应用是生成出来的代码，可能有 bug，也可能被注入。

安全不靠「削减 Agent 的权限」，而靠以下四点：

1. **能回滚，就不用问。**
   - 应用的每个版本都有 git 记录。
   - 数据层保留修改历史，删除是软删除。
   - VM 有快照。
   - 绝大多数操作做完还能撤销，所以可以直接执行。
2. **只有不可逆的对外操作需要把关**，比如发邮件、发布文章、付款、删除 AgentOS 之外的文件。按权限模式处理：

   | 模式 | 行为 |
   |---|---|
   | 谨慎 | 每次都确认 |
   | **自动（默认）** | 直接执行，只有当 Agent 的上下文里混入了不可信内容（网页、邮件）时才确认 |
   | 完全信任 | 从不确认，只记日志 |
3. **权力属于用户和 Agent，网页和邮件内容只是数据。** 提示注入的防线放在「指令来源」上：靠污点标记，再把不可信内容交给没有任何工具的隔离模型去解析。这样不需要限制 Agent 的能力。
4. **全程可见、可撤销。**
   - 「活动流」里能看到 Agent 自主做过的每件事，每条都有撤销入口。
   - 主动订阅触发的自主行动有每日费用上限和频率上限，防止事件风暴或循环把钱烧光。

### 4.11 端到端示例

1. Mail（可信的 Swift 邮件服务）发出 `mail.received` 事件，`trust=untrusted`，`data` 里只有 `messageId`、`from` 和标题。
2. Notes 应用安装时获得了 `subscribes:["mail.received"]` 和 `calls:["mail.get"]` 两项授权。它收到事件后调用 `mail.get` 取正文；正文带着污点标记返回，Notes 存下的笔记也继承这个污点。
3. 用户说「找一下 Alice 关于 Q3 的邮件」。Agent 先用 `apps.search` 找到并加载 `mail.search`，调用后拿到结构化结果，这次调用写入审计日志。
4. Agent 接着想用 `mail.send` 回信，但它的上下文里带着被污染的正文，于是宿主弹出确认框，展示收件人和内容，用户同意后才发送。

---

## 5. 修订后的路线图

协议和总线是 AgentOS 最核心的差异化，所以提到最前面，先用现有的 JS 应用跑通。

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P0**（已完成） | WebView 运行时、Builder、自测闭环、OpenRouter | 一句话生成可玩的游戏 |
| **P1 协议与总线** | JS shim 支持 `agentos.tools.register`、`agentos.events.*` 和 `agentos.call`；宿主实现 MCP Router 和 Event Broker（SQLite）；清单加入 `interface` 块，并实现工具快照锁定；能力授权和宿主确认框；Builder 被强制生成接口、Skill 和契约测试；Agent 使用元工具和按需加载；`aos` CLI；`.agentpkg` 格式和版本回滚；共享领域 schema 第一版（笔记、任务、文档） | 生成「笔记」和「待办」两个应用：Agent 能通过协议操作它们；待办能订阅笔记里新增的 TODO；所有调用都有审计记录 |
| **P2 工作间与第一条纵向链路** | 基于 Containerization 的 Workbench VM，加上出站代理；Operator Agent；搜索和浏览器服务；数据层；**研究助手 → 文档/博客** | 「研究 X 并写成博客草稿」整条链路跑通，全程可追溯 |
| **P3 原生应用与通信** | B 类：本地编译、Seatbelt 沙箱、`--mcp` stdio；邮件服务（IMAP）、污点标记、先计划后执行的自动化；媒体服务 | 原生应用和 JS 应用在总线上平等互通；邮件到达后自动触发的任务可控、可审计 |
| **P4 云构建与自我演化** | C 类：自带 GitHub 账号的构建、构建证明校验；WASM 模块；可生成的外壳和恢复模式；可选的 macOS 来宾 VM，用于操作真实 Mac 应用 | — |

---

## 6. 风险与待决问题

**风险：**

1. **MCP 本身变动很大。** 2026-07-28 是一次不兼容的大改，事件草案也还没被接纳。对策：内部协议保持「MCP 形状」，外面包一层适配器，并锁定版本。
2. **提示注入**会借总线放大，需要第 4.9 节的整套机制。Agent 拿到极大权限后，这是最需要盯紧的风险。污点标记粒度太粗，就会频繁弹确认框，用户会疲于点确认，需要在交互设计上下功夫。
3. **VM 内存不还给宿主**，Containerization 才 1.0 不久（只支持 macOS 26 以上），Linux 的 Rosetta 在 macOS 27 之后会不会继续保留也是未知数。
4. **Apple 政策**：签名、Xcode 许可、`sandbox-exec` 已弃用、ad-hoc 签名代码将来可能被收紧。
5. **生成接口的质量会漂移**：需要共享 schema、lint 和契约测试来兜底。
6. **常驻成本**：几百个订阅者、隐藏 WebView 和 VM 加在一起的耗电和内存占用。

**决策记录（2026-10-15）：**

1. 「体验像 Parallels、实现像 WSL2」：已补充解释，待创始人确认。
2. C 类采用用户自带 GitHub 账号构建：**已同意**。
3. B 类要求安装 Command Line Tools：**已同意**。
4. Agent 可以主动订阅事件，系统应给 Agent 极大权限：**已同意**，权限模型见第 4.10 节。

---

## 7. 主要来源

- MCP 2026-07-28 版本变更：https://modelcontextprotocol.io/specification/2026-07-28/changelog ；订阅：https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions
- MCP 事件草案：https://github.com/modelcontextprotocol/experimental-ext-triggers-events ；工作组：https://modelcontextprotocol.io/community/working-groups/triggers-events
- Windows 上的 MCP：https://learn.microsoft.com/en-us/windows/ai/mcp/overview ；隔离设计：https://learn.microsoft.com/en-us/windows/ai/mcp/servers/mcp-containment
- Android AppFunctions：https://developer.android.com/ai/appfunctions ；Apple App Intents（WWDC26）：https://developer.apple.com/videos/play/wwdc2026/345/
- CloudEvents：https://cloudevents.io/ ；NATS 授权：https://docs.nats.io/running-a-nats-service/configuration/securing_nats/authorization
- Anthropic 高级工具使用：https://www.anthropic.com/engineering/advanced-tool-use ；在代码中调用 MCP：https://www.anthropic.com/engineering/code-execution-with-mcp
- 致命三要素：https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/ ；FIDES：https://www.microsoft.com/en-us/research/publication/securing-ai-agents-with-information-flow-control/ ；CaMeL 等设计模式：https://arxiv.org/abs/2506.08837
- Apple Containerization：https://github.com/apple/containerization ；container 发布记录：https://github.com/apple/container/releases
- Virtualization 新特性（WWDC26）：https://developer.apple.com/videos/play/wwdc2026/224/ ；WSLg：https://github.com/microsoft/wslg ；Crostini：https://chromium.googlesource.com/chromiumos/docs/+/master/containers_and_vms.md
- E2B Desktop：https://github.com/e2b-dev/desktop ；Cua/Lume：https://github.com/trycua/cua
- Xcode 与 Apple SDK 许可：https://www.apple.com/legal/sla/docs/xcode.pdf ；开发者计划许可协议：https://developer.apple.com/support/terms/apple-developer-program-license-agreement/
- GitHub Actions 计费：https://docs.github.com/en/billing/reference/actions-runner-pricing ；构建证明离线校验：https://docs.github.com/en/enterprise-cloud@latest/actions/how-tos/secure-your-work/use-artifact-attestations/verify-attestations-offline
- 文件隔离标记：https://developer.apple.com/documentation/bundleresources/information-property-list/lsfilequarantineenabled ；如何运行未公证的代码：https://eclecticlight.co/2026/08/11/how-can-you-run-code-that-hasnt-been-notarised/
- WASI 0.3：https://wasi.dev/releases/wasi-p3 ；WasmKit：https://github.com/swiftwasm/WasmKit/releases
