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
| 虚拟文件系统 | `agentos://<appId>/<path>` 映射到应用目录；每个应用的 host 不同，所以 origin 也各自独立；`index.html` 不存在时返回「正在生成」的占位页。每个请求按发起它的 WebView 校验 host（第 5 节） | `App/Runtime/AppSchemeHandler.swift` |
| CSP 响应头 | `default-src 'none'; script-src agentos: 'unsafe-inline' blob:; style-src agentos: 'unsafe-inline'; img-src agentos: data: blob:; media-src agentos: data: blob:; font-src agentos: data:; connect-src agentos: data: blob:; worker-src agentos: blob:; base-uri 'none'; form-action 'none'` | 同上 |
| 拦截外网 | `WKContentRuleList` 屏蔽 `^https?://` 和 `^wss?://`，作为 CSP 之外的第二道防线 | `App/Runtime/RuntimeManager.swift` |
| 导航策略 | 主 frame 只允许本应用的 origin 和 `about:blank`；子 frame 另外允许 `about:srcdoc`，其余由 CSP 的 `frame-src`（回落到 `'none'`）拦截；`window.open` 一律拒绝 | `RuntimeController` |
| 关闭 WebRTC | 私有偏好 `_peerConnectionEnabled = false`；另有注入所有 frame 的脚本删除 `RTCPeerConnection` | `RuntimeManager` |
| 存储隔离 | 每个应用一个 `WKWebsiteDataStore(forIdentifier: appUUID)`；删除应用时一并删除 | `RuntimeManager` |
| 消息来源校验 | 只接受顶层 frame、且 origin 等于本应用的消息，因为沙箱 iframe 也能调用 messageHandlers（实测） | `RuntimeController.userContentController` |
| 崩溃恢复 | WebContent 进程退出时，记一条错误日志并自动重载 | `webViewWebContentProcessDidTerminate` |

**P0 实测出的问题**（[sandbox-probes/](../research/sandbox-probes/)）已在 P1a 第一步修复（第 5 节），`make sandbox-test` 防止回退：

- scheme handler 不校验 host：应用导航到 `agentos://..`，就能同源读取 `~/Library/Application Support/AgentOS/` 下的任意文件（已实测读到 `meta/` 和 `logs/`）；用 `<script src>` 还能执行其他应用的脚本。
- 导航策略放行所有 `agentos:` URL，不限定本应用。
- `RTCPeerConnection` 可用，CSP 和规则列表都管不到 WebRTC。
- 宿主的测试钩子 `window.__agentos` 是可写的全局变量，宿主在 page world 里执行 `evaluate`，应用可以伪造自测结果。

### 3.2 注入的脚本

页面一开始加载就注入到主 frame，分在两个 world：

| 脚本 | world | 内容 |
|---|---|---|
| `App/Runtime/agentos-shim.js` | page world（和应用代码同处） | 捕获控制台和错误、统计帧数、键盘处理、应用 API `agentos.*` |
| `App/Runtime/agentos-host.js` | 宿主自己的 `WKContentWorld`（`agentos-host`） | 测试钩子 `__agentos`（模拟输入、读帧数和状态）；宿主的 `evaluate` 也只在这里执行 |

page world 里的 shim：

- **捕获控制台和错误**：`console.*`、`error`（带文件、行号、调用栈）、`unhandledrejection`、`securitypolicyviolation`（报告「被 AgentOS 沙箱拦截」）。每秒最多上报 100 条，错误不受这个限制。
- **统计帧数**：包装 `requestAnimationFrame`，用来判断渲染循环是否还在运行。
- **键盘处理**：焦点不在输入框时，对按键 `preventDefault`，避免页面滚动和系统提示音；按钮和链接上的回车、空格不受影响。
- **应用 API**：`agentos.expose(fn)`，应用通过它把状态暴露给 Agent 的自测。P1a 的其余 `agentos.*`（见 [05](05-app-protocol.md) 第 7 节）也留在 page world，但它发出的消息不带任何权限，身份由宿主按 WebView 绑定判定（[00](00-kernel.md) 第 4 节）。

宿主 world 里的测试钩子：

- **模拟输入**：`__agentos.key(type, key)` 会补齐 `code`、`keyCode` 和 `which`；`__agentos.click(x, y)` 依次派发 pointer、mouse、click 事件。两个 world 共享 DOM，事件照常到达页面的监听器。`keyCode`、`which` 要写进 `KeyboardEvent` 的初始化字典（WebKit 仍接受这两个旧字段）；在宿主 world 的事件对象上 `defineProperty`，页面看不到（实测）。
- **读帧数和状态**：两个 world 不共享 JS 对象。钩子向页面派发一个同步的 DOM 事件，shim 在应用代码运行前就注册了监听，回一个 JSON 字符串。帧数和 `expose` 的状态本来就由应用自己报告，应用可以谎报；content world 保护的是钩子本身和宿主执行的代码：应用无法替换 `__agentos`，也无法篡改宿主 `evaluate` 用到的 `JSON` 等内置对象。

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

| # | 措施 | 解决什么 | 状态 |
|---|---|---|---|
| 1 | **scheme handler 绑定 WebView**：URL 的 host 必须是注册表里存在的应用 ID（UUID），并且等于发起请求的 WebView 所属的应用；否则 403 | 越界读取宿主数据、读取其他应用的文件 | ✅ |
| 2 | **只服务应用目录**：开发中服务 `apps/<id>/src/`，版本化之后服务 `apps/<id>/current/`；宿主数据挪到 `system/`（[00](00-kernel.md) 第 9 节）；`/_lib/` 从 App 包里只读提供 | 同上，多一层保障 | 随目录迁移做 |
| 3 | **导航只允许本应用的 origin 和 `about:blank`** | 借导航切换 origin | ✅ |
| 4 | **测试钩子放进独立的 content world**；`evaluate` 不再在 page world 里执行 | 应用伪造自测和契约测试结果 | ✅ |
| 5 | **关闭 WebRTC**：WKWebView 没有公开开关，AgentOS 不上 App Store，可以使用私有的 `_peerConnectionEnabled`；另用注入所有 frame 的脚本删除 `RTCPeerConnection` 作为补充 | 绕过 CSP 的外泄通道 | ✅ |
| 6 | **沙箱回归用例**：现有的 `sandbox-escape.html` 加上三个探针，放进 `tests/fixtures/`，`make sandbox-test` 一键运行，改动运行时必须全部通过 | 防止回退 | ✅ |

实现要点：

| 项 | 做法 |
|---|---|
| 绑定表 | 在 `AppSchemeHandler` 里，按 WebView 对象记录 appId（弱引用，防止对象地址复用）。`RuntimeManager` 在首次加载前绑定、移除应用时解绑；没绑定的 WebView 一律 403。host 还必须是规范的小写 UUID，带端口的 URL 也拒绝 |
| 符号链接 | 解析符号链接之后再判断文件是否在应用目录内，Agent 在应用目录里放的链接指不出去 |
| `blob:`、`data:` | 主 frame 不再放行。现有用例和 Builder 约定都不需要；以后要导出文件，另做宿主中转的下载，不放开导航 |
| 拦截记录 | 被拒的请求和导航写进事件日志（`scheme_request_denied`、`navigation_blocked`）；导航被拦时，应用控制台也会收到一条 error |
| WebRTC 两层 | 分别去掉一层实测：只用私有偏好、只用脚本，主 frame、srcdoc iframe、新 iframe 的初始文档里都没有 `RTCPeerConnection`。私有偏好不存在时（WebKit 改名），记一条错误日志，只剩脚本这一层 |

回归用例（`make sandbox-test`，运行器是 `scripts/sandbox-test.ts`）：

| 用例 | 测什么 |
|---|---|
| `sandbox-escape.html` | `fetch`、远程 `import`、WebSocket 访问外网 |
| `sandbox-probe1-egress-and-isolation.html` | 读取其他应用的文件和脚本（注册过的邻居应用、没注册的 ID）、`agentos://..` 越界读取、主 frame 和 iframe 里的 WebRTC、测试钩子在 page world 是否可见 |
| `sandbox-probe2-iframe-traversal.html` | 用 iframe 在 `agentos://..` 下同源读取；WebRTC 收集候选 |
| `sandbox-probe3-toplevel-traversal.html` | 主 frame 导航到 `agentos://..`、邻居应用、`data:` URL |

运行器逐个用 `--selftest-runtime <用例> --selftest-neighbor` 启动 App（后一个参数让自测多建一个邻居应用，探针从 `selftest-context.json` 读到它的 ID），读 `logs/selftest-result.json` 里探针暴露的状态，按运行器里的期望逐项判定；探针没跑完也算失败，免得「什么都没测」被当成通过。三个探针由 [sandbox-probes/](../research/sandbox-probes/) 改写而来，只记录状态码、长度和布尔值。

实测（M5 Pro / macOS 26.5）：22 项检查，在修复前的构建上 13 项失败（包括执行邻居应用的脚本、经顶层导航读到 `meta/<id>/manifest.json`），修复后全部通过；贪吃蛇自测照常通过（约 60 fps）。

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

## 重建运行时与实测（2026-10-16）

新实现位于 `Sources/AgentOSRuntime/`，前文 `App/Runtime/` 路径属于原型。Web 核心与 UI 共用资源校验，核心用 `.none` 调度，UI 用 `.suspend`。工具返回值经过 IDL 校验；核心按 8 个实例上限和空闲时间回收，热重载保留来源标签。

| 类型 | 当前实现 | 实测与限制 |
|---|---|---|
| Web | 同应用 scheme、CSP、内容规则、顶层来源检查、隔离宿主 world | 全套沙箱回归通过；独立解析网页和 MIME，不运行来源脚本 |
| 原生 | 受限 swiftc 编译 `Sources/*.swift`，宿主组装 `.app`；核心和 UI 各自独立进程，通过有界 NDJSON 调用宿主 | 编译、契约、共享数据、默认禁网/宿主文件隔离、异常退出后重启通过；原生窗口交互另验 |
| WASM | `runtime.kind=wasm-component` 加 `runtime.module`；`agentos.wasm.load()` 载入同源 core module v1，JS 包装 IDL 工具 | 整数计算模块已在真实 WebKit 验证；名称沿用原方案，但不实现 Component Model 或 WASI |

S1 补测完成：无窗口运行 3600.105 秒，721 次调用、零失败，p95 13.316 ms；宿主峰值 RSS 69,107,712 字节，单个 WebContent 采样峰值 30,261,248 字节。见[原始记录](../verification/2026-10-16-core-host-memory.json)。这些数字只代表本机此探针，不能推算复杂应用的内存。

应用后端：Web 核心通过 `agentos.backend.call(method,args)` 调用自己的 Python/Node/OCI 服务。每应用独立无网 VM 和磁盘，最多两个驻留后端；契约测试使用单独临时 VM。Node/Python 接收 UTF-8 源码，OCI 接收经验证的镜像布局归档；两者使用同一 stdin/stdout NDJSON 协议。后端不会获得宿主 bridge token；输出始终带私人和后端来源标签。见 [VM 说明](../../vm/README.md)。
