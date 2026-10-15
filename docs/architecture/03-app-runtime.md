# 03 应用运行时

> 所属：[技术方案总览](README.md) ｜ 相关：[00 内核](00-kernel.md)、[04 应用包](04-app-package.md)、[05 协议](05-app-protocol.md)、[09 安全](09-security.md)、[10 工作间 VM](10-workbench-vm.md)
>
> 依据：[native-vs-web.md](../research/native-vs-web.md)、[webkit-experiments/](../research/webkit-experiments/)、[sandbox-probes/](../research/sandbox-probes/)

## 1. 职责

承载并隔离生成出来的应用：加载与热更新、捕获输入输出和错误、提供 Agent 自测用的运行时工具、注入 `agentos.*` SDK、执行应用核心的工具和订阅、管理生命周期和资源。

## 2. 运行时类型

| 类型 | 承载 | 对应 | 适合做什么 | 阶段 |
|---|---|---|---|---|
| **界面 WebView** | 每个打开的应用一个 WKWebView，显示在应用区 | A 类应用的界面 | 游戏、工具、文档、邮件界面……绝大多数应用 | P0 ✅ |
| **核心宿主** | 每个活跃应用一个**隐藏的** WKWebView，只加载 `core.js` | A 类应用的核心 | 工具、订阅、数据逻辑；应用没打开时也能被调用 | P1a |
| **原生进程** | 独立进程，Seatbelt 沙箱，独立窗口 | B / C 类 | Metal 重度渲染、120 Hz、深度系统集成 | P4 |
| **WASM** | 在核心宿主里运行，或放进 Wasmtime 辅助进程 | W 类 | 计算模块、无界面工具 | P4 |
| **VM 内服务** | Workbench VM 或临时微虚拟机 | O 类 | 应用后端、爬虫、数据处理（见 [10](10-workbench-vm.md)） | P3 |

**不做进程内动态库加载**，因为实测证明它有三个无法解决的问题：生成代码一崩溃宿主就跟着崩溃；加载过的库卸载不掉；生成代码拥有宿主的全部权限，能读到钥匙串里的 API Key。

## 3. 界面 WebView（P0 已实现）

### 3.1 加载与隔离

| 机制 | 实现 | 代码 |
|---|---|---|
| 虚拟文件系统 | `agentos://<appId>/<path>` 映射到应用目录；每个应用的 host 不同，所以 origin 也各自独立；`index.html` 不存在时返回「正在生成」的占位页 | `App/Runtime/AppSchemeHandler.swift` |
| CSP 响应头 | `default-src 'none'; script-src agentos: 'unsafe-inline' blob:; style-src agentos: 'unsafe-inline'; img-src agentos: data: blob:; media-src agentos: data: blob:; font-src agentos: data:; connect-src agentos: data: blob:; worker-src agentos: blob:; base-uri 'none'; form-action 'none'` | 同上 |
| 拦截外网 | `WKContentRuleList` 屏蔽 `^https?://` 和 `^wss?://`，作为 CSP 之外的第二道防线 | `App/Runtime/RuntimeManager.swift` |
| 导航策略 | 只允许 `agentos:`、`about:`、`blob:`、`data:`；`window.open` 一律拒绝 | `RuntimeController` |
| 存储隔离 | 每个应用一个 `WKWebsiteDataStore(forIdentifier: appUUID)`；删除应用时一并删除 | `RuntimeManager` |
| 消息来源校验 | 只接受顶层 frame、且 origin 等于本应用的消息，因为沙箱 iframe 也能调用 messageHandlers（实测） | `RuntimeController.userContentController` |
| 崩溃恢复 | WebContent 进程退出时，记一条错误日志并自动重载 | `webViewWebContentProcessDidTerminate` |

**P0 实测出的问题**（[sandbox-probes/](../research/sandbox-probes/)），在 P1a 第一步修复，见第 5 节：

- scheme handler 不校验 host：应用导航到 `agentos://..`，就能同源读取 `~/Library/Application Support/AgentOS/` 下的任意文件（已实测读到 `meta/` 和 `logs/`）。
- 导航策略放行所有 `agentos:` URL，不限定本应用。
- `RTCPeerConnection` 可用，CSP 和规则列表都管不到 WebRTC。
- 宿主的测试钩子 `window.__agentos` 是可写的全局变量，宿主在 page world 里执行 `evaluate`，应用可以伪造自测结果。

### 3.2 注入的 shim（`App/Runtime/agentos-shim.js`）

页面一开始加载就注入到主 frame：

- **捕获控制台和错误**：`console.*`、`error`（带文件、行号、调用栈）、`unhandledrejection`、`securitypolicyviolation`（报告「被 AgentOS 沙箱拦截」）。每秒最多上报 100 条，错误不受这个限制。
- **统计帧数**：包装 `requestAnimationFrame`，用来判断渲染循环是否还在运行。
- **键盘处理**：焦点不在输入框时，对按键 `preventDefault`，避免页面滚动和系统提示音；按钮和链接上的回车、空格不受影响。
- **模拟输入**：`__agentos.key(type, key)` 会补齐 `code`、`keyCode` 和 `which`；`__agentos.click(x, y)` 依次派发 pointer、mouse、click 事件。
- **应用 API**：`agentos.expose(fn)`，应用通过它把状态暴露给 Agent 的自测。

P1a 起，shim 拆成两部分：**测试钩子**放进独立的 `WKContentWorld`（应用的代码碰不到）；**应用 API**（`agentos.*`，见 [05](05-app-protocol.md) 第 7 节）留在 page world，但它发出的消息不带任何权限，身份由宿主按 WebView 绑定判定（[00](00-kernel.md) 第 4 节）。

### 3.3 生成物约定（写进 Builder 的系统提示）

- 应用由核心和界面两部分组成（第 4 节）。界面默认是一个自包含的 `ui/index.html`，超过约 800 行再拆成 ES 模块；不需要构建步骤，不用 TS、JSX 或 npm。
- 不联网。所需的库全部内置在本地并固定版本，通过 import map 从同源的 `/_lib/` 引入（[07](07-system-services.md) 第 4 节）。
- 铺满整个面板，处理 `devicePixelRatio` 和窗口大小变化；动画用 rAF 加 delta-time；页面隐藏时暂停。
- 素材用程序绘制，音效用 Web Audio 合成。
- **数据放哪里**：对用户有长期价值、可能被其他应用或 Agent 使用的数据，进入共享集合（[08](08-data.md)）；界面状态、缓存、游戏存档放在 `localStorage`（每个应用独立）。

### 3.4 运行时工具（由宿主执行，供 Builder 自测）

| 工具 | 输入 | 输出 | 阶段 |
|---|---|---|---|
| `run_app` | — | `{loaded, load_error, load_ms, errors[], warnings[], logs[], exposes_state, visibility}` | P0 |
| `smoke_test` | `{inputs?, checks?, duration_ms?=2500, reload?=true}` | `{pass, visible, checks:{…}, fps, errors[], state_before, state_after}` | P0 |
| `send_input` | `{steps:[{action: press/down/up/wait/click, key?, ms?, x?, y?}]}` | `{console[], state}` | P0 |
| `get_console` | `{since_seq?, levels?, limit?, target?: ui/core}` | `{entries[], last_seq}` | P0（P1a 加 `target`） |
| `screenshot` | — | 图片，长边最大 1024 px | P0 |
| `inspect_state` | — | `agentos.expose()` 返回的状态 | P0 |
| `set_app_info` | `{title, icon}` | — | P0 |
| `call_tool` | `{tool, args}` | 调用应用自己的工具，结果和 `apps.call` 相同 | P1a |
| `run_contract_tests` | — | 逐条结果（[05](05-app-protocol.md) 第 13 节） | P1a |

`smoke_test` 的检查项：

| 检查项 | 判定方法 |
|---|---|
| no_errors | 期间没有 error 级别的日志，页面也成功加载 |
| nonblank | 把截图缩到 192×192，占比最大的颜色不超过 99.95% |
| frames_advancing | 期间 rAF 至少回调 10 次 |
| visual_change | 前后两张截图有超过 0.1% 的像素发生变化 |
| state_changes | `expose` 暴露的状态在输入前后不同 |

**窗口不可见时**，WebKit 会暂停渲染和 rAF。这时与画面相关的三项检查会标记为跳过，并说明原因，避免 Agent 去修根本不存在的 bug。

### 3.5 实测数据（M5 Pro / macOS 26.5）

| 项 | 数据 |
|---|---|
| 首个 WebView 冷启动 | 约 1.1 s |
| 后续 WebView 热启动 | 46 ms |
| 重新加载 | 4–6 ms |
| 帧率 | 约 60 fps 上限（120 Hz 屏幕上也是），游戏必须用 delta-time |
| 图形与媒体能力 | WebGPU、WebGL2、Web Audio 可用，`AudioContext` 不需要用户手势就能 resume |
| 死循环 | 宿主不受影响，但 WebView 释放后，WebContent 进程仍会占满 CPU，而且没有公开 API 能杀掉它 |

### 3.6 界面的热更新

1. **整页重载并交接状态（默认）**：重载前调用应用的 `saveState`，重载后在页面开始加载时注入回去。P0 还只做了整页重载。
2. **模块替换**：按 `mount(root, prevState)` / `unmount()` 的约定，用 `import()` 加载新版本的模块，页面不刷新。
3. **双缓冲**：在一个隐藏的热 WebView 里加载新版本，就绪后再切换显示；新版本报错就自动退回旧版本。

## 4. 应用结构：核心与界面

### 4.1 为什么拆分

协议和总线建立在一个前提上：应用没打开时，宿主也能执行它的工具、处理它的订阅。直接拿界面页面来做有三个问题：WebKit 会暂停不可见的页面；界面代码一启动就画画、放音乐，和「被调用一个工具」无关；Builder 每改一次界面，订阅就被打断。所以把应用拆成两部分：

| 部分 | 内容 | 运行在 | 主体 |
|---|---|---|---|
| **核心** `core.js` | 工具处理函数、事件订阅、数据读写；不碰 DOM | 核心宿主（隐藏 WebView） | `app:<id>/core`，持有应用的能力授权 |
| **界面** `ui/` | 渲染和交互 | 界面 WebView | `app:<id>/ui`，对共享数据只读 |

这同时带来三个好处：无界面执行可靠；界面修改数据必须调用核心的工具，所以接口和界面的能力天然一致；契约测试只需要加载核心。

纯游戏这类没有共享数据的应用，核心可以几乎为空（例如只提供 `highscores.list`）；它照样在注册表里，可以被 Agent 打开和描述。

### 4.2 核心宿主

- 每个活跃应用一个隐藏的 WKWebView，加载宿主生成的包装页 `agentos://<appId>/_core`，包装页再以 ES 模块加载 `core.js`。
- 和界面 WebView 使用**同一套隔离**：同一个 origin 和数据存储、同样的 CSP 和规则列表、同样的身份绑定（第 5 节）。
- `inactiveSchedulingPolicy` 设为 `.none`，避免被挂起。不在窗口里的 WebView，定时器、Promise、消息桥和 `callAsyncJavaScript` 的行为需要实测（S1，[11](11-engineering.md) 第 8 节）；如果不可靠，退路是把隐藏 WebView 挂在一个屏幕外的透明窗口上。
- 规模上来之后（几十个活跃应用），再评估「JavaScriptCore 上下文 + 沙箱化的 XPC 辅助进程」作为更轻的核心宿主（对比见 [tech-assessment.md](../research/tech-assessment.md) 第 4.2 节）。

### 4.3 核心的生命周期

| 时机 | 行为 |
|---|---|
| 启动 | 按需：有工具调用、有事件要投递、界面打开时 |
| 就绪 | 页面加载完成，且 `interface.json` 里声明的工具都已注册；5 秒内没注册完的工具标为不可用 |
| 空闲回收 | 默认 5 分钟没有调用、没有待投递的事件、界面也没打开，就回收 |
| 并发上限 | 同时运行的核心默认不超过 8 个，超出时按最近最少使用回收 |
| 崩溃 | 自动重启，指数退避；1 分钟内崩溃 3 次就标为不可用，在活动流里告警 |
| 卡死 | 宿主定期探活；超时就丢弃这个 WebView 并重建。WebContent 进程可能仍在空转，这是已知限制；可以评估私有的 `_killWebContentProcess` |

### 4.4 界面和核心的关系

- 界面通过 `agentos.self.call` 调用核心，经过宿主转发；核心不运行时，宿主先拉起它。
- 界面可以直接**读**共享数据（例如列表渲染），但写入只能经过核心的工具；宿主按主体执行这条规则（[00](00-kernel.md) 第 3.1 节）。
- 高频写入（例如编辑器自动保存）在界面里防抖后再调用工具。

### 4.5 核心的热重载

Builder 修改 `core.js` 时：

1. 宿主暂停向这个核心投递事件（事件留在总线上，游标不前进）。
2. 等进行中的调用完成，最多 2 秒，超时就以 `unavailable` 失败。
3. 重载核心，等工具重新注册。
4. 恢复投递，从游标处补发。

只改界面时，核心不受影响。

## 5. 隔离加固（P1a 第一步）

| # | 措施 | 解决什么 |
|---|---|---|
| 1 | **scheme handler 绑定 WebView**：URL 的 host 必须是注册表里存在的应用 ID（UUID），并且等于发起请求的 WebView 所属的应用；否则 403 | 越界读取宿主数据、读取其他应用的文件 |
| 2 | **只服务应用目录**：开发中服务 `apps/<id>/src/`，版本化之后服务 `apps/<id>/current/`；宿主数据挪到 `system/`（[00](00-kernel.md) 第 9 节）；`/_lib/` 从 App 包里只读提供 | 同上，多一层保障 |
| 3 | **导航只允许本应用的 origin 和 `about:blank`** | 借导航切换 origin |
| 4 | **测试钩子放进独立的 content world**；`evaluate` 不再在 page world 里执行 | 应用伪造自测和契约测试结果 |
| 5 | **关闭 WebRTC**：WKWebView 没有公开开关，AgentOS 不上 App Store，可以使用私有的 `_peerConnectionEnabled`；另用注入所有 frame 的脚本删除 `RTCPeerConnection` 作为补充 | 绕过 CSP 的外泄通道 |
| 6 | **沙箱回归用例**：现有的 `sandbox-escape.html` 加上三个探针，放进 `tests/fixtures/`，`make sandbox-test` 一键运行，改动运行时必须全部通过 | 防止回退 |

已知限制：同源的 srcdoc iframe 里，全局对象是干净的（shim 只注入主 frame）。任何「在 shim 里禁用某个 API」的做法，都要同时考虑 iframe；能在 WebKit 配置层面关掉的，不在 JS 层面做。

## 6. 原生进程运行时（P4）

- **启动**：由宿主拉起 `apps/<id>/current/<Name>.app/Contents/MacOS/<Name>`，并套用一份 Seatbelt 规则。规则由宿主根据能力授权生成：默认拒绝一切，只允许读写应用自己的数据目录；网络默认关闭，需要联网时只能经过宿主的出站代理。
- **协议**：以 `--mcp` 参数启动时，通过 stdio 说 MCP；宿主保持一条长连接（[05](05-app-protocol.md) 第 6 节）。
- **窗口**：应用自己的 `NSWindow` 作为独立窗口，宿主负责管理（激活、关闭、在 Dock 里显示）。将来可以考虑 IOSurface 远程渲染，把画面嵌进 AgentOS 的应用区。
- **自测工具**：截窗口图（ScreenCaptureKit，需要用户授权屏幕录制）、注入 `NSEvent` 模拟输入、通过 MCP 工具读取状态。
- **实测**：编译 0.3–0.7 s；新二进制首次启动有约 0.5 s 的系统安全扫描；进程冷启动约 0.6 s，热启动约 0.12 s。

## 7. 资源

| 项 | 策略 |
|---|---|
| 预热 | App 启动时预热 1–2 个界面 WebView，因为首个冷启动要 1.1 s |
| 后台界面 | 界面 WebView 用 `inactiveSchedulingPolicy = .suspend`；核心宿主用 `.none` |
| 并发上限 | 打开的界面 WebView 和运行的核心各有上限，最近最少使用的先回收 |
| 原生进程 | 限制 CPU 和内存（P4） |

## 8. 里程碑

| 阶段 | 内容 |
|---|---|
| P0 ✅ | 界面 WebView、CSP 和规则列表、shim、运行时工具、可见性处理 |
| P1a | 隔离加固和沙箱回归用例（第 5 节）；核心宿主和生命周期；SDK 注入（`tools`、`self.call`、`data`）；`call_tool`、`run_contract_tests`；内置库和 import map；界面状态交接 |
| P1b | 多应用并行（标签页）；核心的事件投递和热重载 |
| P2 | 双缓冲热更新 |
| P3 | VM 内服务作为应用后端 |
| P4 | 原生进程运行时（Seatbelt、`--mcp`、窗口管理、自测工具）；WASM |

## 9. 风险与待定

- 核心宿主的内存开销决定了能同时活跃多少个应用，S1 之后再定上限。
- 待定：核心和界面共用同一个 origin 和数据存储，`localStorage` 互通。要不要禁止核心使用 `localStorage`，强制有长期价值的状态进入共享集合？建议不禁止，靠 Builder 的约定和评测来约束。
