# 03 应用运行时

> 所属：[技术方案总览](README.md) ｜ 相关：[04 应用包](04-app-package.md)、[05 协议](05-app-protocol.md)、[09 安全](09-security.md)、[10 工作间 VM](10-workbench-vm.md)
>
> 依据：[native-vs-web.md](../research/native-vs-web.md)、[webkit-experiments/](../research/webkit-experiments/)

## 1. 职责

承载并隔离生成出来的应用。具体包括：加载与热更新、捕获输入输出和错误、提供 Agent 自测用的运行时工具、注入 `agentos.*` SDK、管理生命周期和资源。

## 2. 运行时类型

| 类型 | 承载 | 对应产物 | 适合做什么 | 阶段 |
|---|---|---|---|---|
| **Web（默认）** | 每个应用一个 WKWebView | A 类 | 游戏、工具、文档、邮件界面……绝大多数应用 | P0 ✅ |
| **原生进程** | 独立进程，Seatbelt 沙箱，独立窗口 | B / C 类 | Metal 重度渲染、120 Hz、深度系统集成 | P3 |
| **WASM** | 在 WebView 里运行，或放进 Wasmtime 辅助进程 | W 类 | 计算模块、无界面工具 | P4 |
| **VM 内服务** | Workbench VM 或临时微虚拟机 | O 类 | 应用后端、爬虫、数据处理（见 [10](10-workbench-vm.md)） | P2 |

**不做进程内动态库加载**，因为实测证明它有三个无法解决的问题：生成代码一崩溃宿主就跟着崩溃；加载过的库卸载不掉；生成代码拥有宿主的全部权限，能读到钥匙串里的 API Key。

## 3. Web 运行时（P0 已实现）

### 3.1 加载与隔离

| 机制 | 实现 | 代码 |
|---|---|---|
| 虚拟文件系统 | `agentos://<appId>/<path>` 映射到 `apps/<appId>/<path>`；每个应用的 host 不同，所以 origin 也各自独立；`index.html` 不存在时返回「正在生成」的占位页 | `App/Runtime/AppSchemeHandler.swift` |
| CSP 响应头 | `default-src 'none'; script-src agentos: 'unsafe-inline' blob:; style-src agentos: 'unsafe-inline'; img-src agentos: data: blob:; media-src agentos: data: blob:; font-src agentos: data:; connect-src agentos: data: blob:; worker-src agentos: blob:; base-uri 'none'; form-action 'none'` | 同上 |
| 拦截外网 | `WKContentRuleList` 屏蔽 `^https?://` 和 `^wss?://`，作为 CSP 之外的第二道防线 | `App/Runtime/RuntimeManager.swift` |
| 导航策略 | 只允许 `agentos:`、`about:`、`blob:`、`data:`；`window.open` 一律拒绝 | `RuntimeController` |
| 存储隔离 | 每个应用一个 `WKWebsiteDataStore(forIdentifier: appUUID)`；删除应用时一并删除 | `RuntimeManager` |
| 消息来源校验 | 只接受顶层 frame、且 origin 等于本应用的消息，因为沙箱 iframe 也能调用 messageHandlers（实测） | `RuntimeController.userContentController` |
| 崩溃恢复 | WebContent 进程退出时，记一条错误日志并自动重载 | `webViewWebContentProcessDidTerminate` |

### 3.2 注入的 shim（`App/Runtime/agentos-shim.js`）

页面一开始加载就注入到主 frame：

- **捕获控制台和错误**：`console.*`、`error`（带文件、行号、调用栈）、`unhandledrejection`、`securitypolicyviolation`（报告「被 AgentOS 沙箱拦截」）。每秒最多上报 100 条，错误不受这个限制。
- **统计帧数**：包装 `requestAnimationFrame`，用来判断渲染循环是否还在运行。
- **键盘处理**：焦点不在输入框时，对按键 `preventDefault`，避免页面滚动和系统提示音；按钮和链接上的回车、空格不受影响。
- **模拟输入**：`__agentos.key(type, key)` 会补齐 `code`、`keyCode` 和 `which`；`__agentos.click(x, y)` 依次派发 pointer、mouse、click 事件。
- **应用 API**：`agentos.expose(fn)`，应用通过它把状态暴露给 Agent 的自测。

### 3.3 生成物约定（写进 Builder 的系统提示）

- 默认是一个自包含的 `index.html`，超过约 800 行再拆成 ES 模块；不需要构建步骤，不用 TS、JSX 或 npm。
- 不联网。所需的库全部内置在本地并固定版本，通过 import map 从同源的 `/_lib/` 引入（P1 落地）。
- 铺满整个面板，处理 `devicePixelRatio` 和窗口大小变化；动画用 rAF 加 delta-time；页面隐藏时暂停。
- 素材用程序绘制，音效用 Web Audio 合成，持久化用 `localStorage`（每个应用独立）。
- P1 起，必须通过 `agentos.tools.register` 注册接口（见 [05](05-app-protocol.md)）。

### 3.4 运行时工具（由宿主执行，供 Agent 调用）

| 工具 | 输入 | 输出 |
|---|---|---|
| `run_app` | — | `{loaded, load_error, load_ms, errors[], warnings[], logs[], exposes_state, visibility}` |
| `smoke_test` | `{inputs?, checks?, duration_ms?=2500, reload?=true}` | `{pass, visible, checks:{…}, fps, errors[], state_before, state_after}` |
| `send_input` | `{steps:[{action: press/down/up/wait/click, key?, ms?, x?, y?}]}` | `{console[], state}` |
| `get_console` | `{since_seq?, levels?, limit?}` | `{entries[], last_seq}` |
| `screenshot` | — | 图片，长边最大 1024 px |
| `inspect_state` | — | `agentos.expose()` 返回的状态 |
| `set_app_info` | `{title, icon}` | — |

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

### 3.6 热更新

1. **整页重载并交接状态（默认）**：重载前调用应用的 `saveState`，重载后在页面开始加载时注入回去。P0 还只做了整页重载。
2. **模块替换**：按 `mount(root, prevState)` / `unmount()` 的约定，用 `import()` 加载新版本的模块，页面不刷新。
3. **双缓冲**：在一个隐藏的热 WebView 里加载新版本，就绪后再切换显示；新版本报错就自动退回旧版本。

## 4. 原生进程运行时（P3）

- **启动**：由宿主拉起 `apps/<id>/current/<Name>.app/Contents/MacOS/<Name>`，并套用一份 Seatbelt 规则。规则由宿主根据清单里的 `permissions` 生成：默认拒绝一切，只允许读写应用自己的数据目录；网络默认关闭，需要联网时只能经过宿主的出站代理。
- **协议**：以 `--mcp` 参数启动时，通过 stdio 说 MCP；宿主会保持一条长连接（见 [05](05-app-protocol.md)）。
- **窗口**：应用自己的 `NSWindow` 作为独立窗口，宿主负责管理（激活、关闭、在 Dock 里显示）。将来可以考虑 IOSurface 远程渲染，把画面嵌进 AgentOS 的应用区。
- **自测工具**：截窗口图（ScreenCaptureKit，需要用户授权屏幕录制）、注入 `NSEvent` 模拟输入、通过 MCP 工具读取状态。
- **实测**：编译 0.3–0.7 s；新二进制首次启动有约 0.5 s 的系统安全扫描；进程冷启动约 0.6 s，热启动约 0.12 s。

## 5. 生命周期与资源

| 项 | 策略 |
|---|---|
| 预热 | App 启动时预热 1–2 个 WebView，因为首个冷启动要 1.1 s |
| 后台挂起 | `inactiveSchedulingPolicy = .suspend`；但有 Agent 任务或订阅正在处理的应用，暂时保持运行 |
| 无界面调用 | 应用没打开时，如果有人调用它的 `headless` 工具，就用一个隐藏的 WebView 加载它，空闲一段时间后回收 |
| 资源上限 | 同时运行的 WebView 数量有上限（LRU 回收）；原生进程限制 CPU 和内存（P3） |
| 卡死检测 | 定期用 `evaluate` 探活，超时就提示「重启该应用」；服务时也可以对循环代码做保护性改写（P1 评估） |

## 6. 里程碑

| 阶段 | 内容 |
|---|---|
| P0 ✅ | Web 运行时、CSP 和规则列表、shim、运行时工具、可见性处理 |
| P1 | 在 shim 里注入 `agentos.tools` / `events` / `call` / `data`；隐藏 WebView 执行 headless 工具；内置库和 import map；多应用并行与资源回收；状态交接 |
| P2 | VM 内服务作为应用后端；双缓冲热更新 |
| P3 | 原生进程运行时（Seatbelt、`--mcp`、窗口管理、自测工具） |
| P4 | WASM 运行时 |
