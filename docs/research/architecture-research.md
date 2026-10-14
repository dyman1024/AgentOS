# AgentOS 技术调研与整体方案

> 调研日期：2026-10-15 ｜ 目标平台：macOS 26.x（本机 26.5.1 / Xcode 26.6）
>
> 标记说明：**[实测]** 在本机跑实验得到（代码见 [webkit-experiments/](webkit-experiments/)）；**[SDK]** 读 macOS 26.5 SDK 头文件 / swiftinterface 得到；**[未核实]** 公开资料无法确认，落地前需要再验证。

---

## 0. 结论速览

1. **生成游戏只有一条路：「代码生成 + Web 沙箱运行时」**。业界有三类「Agent 生成 UI」方案：
   - 生成完整代码，放进沙箱运行（Claude Artifacts、Gemini Dynamic View、MCP Apps）。
   - 声明式组件协议（A2UI、json-render）。
   - 两者混合。

   贪吃蛇、俄罗斯方块、坦克大战这类游戏需要 `requestAnimationFrame` 主循环、Canvas/WebGL、键盘和音频，声明式协议表达不了。

2. **Runtime 选 Swift 原生外壳 + `WKWebView`，不选 Electron、Tauri 或 React Native**。
   - **原理**：每个生成的应用是一个 `agentos://<appId>/index.html`，内容由 `WKURLSchemeHandler` 从本地虚拟文件系统读出。
   - **本机实测**：
     - 热启动一个新视图约 **46 ms**，`reload` 约 **5 ms**。
     - WebGPU、WebGL2、Web Audio、ES Module、import map 都能用。
     - 整个过程**宿主 App 零重编译**。
   - **为什么不选其他三个**：
     - Tauri 在 mac 上底层也是 WKWebView，只是多一层 Rust。
     - Electron 太重。
     - React Native 需要 bundler，也缺少游戏所需的图形栈。

3. **Agent 引擎选 Claude Agent SDK（TypeScript），作为 sidecar 子进程运行**。
   - **它提供什么**：完整的 agent loop、文件读写和编辑工具、hooks、会话恢复、子 Agent、Skills、MCP，都是现成的。
   - **怎么接**：Swift 宿主和它之间用 stdio 上的 JSON-RPC 通信。「运行 / 截图 / 读控制台 / 冒烟测试」等运行时工具以 MCP 工具的形式注册给 Agent，实际由 Swift 执行。
   - **备选**：Swift 原生自写工具循环，直接调 Messages API。如果要上 Mac App Store 或者在意 App 体积，就切到这条路。
   - **协议设计**：按 ACP（Agent Client Protocol）的形状设计，引擎以后可以替换。

4. **决定生成质量的是「生成 → 运行 → 自检 → 修复」闭环**。模型直接写出的代码不保证能玩。必须做到四点：
   - 注入脚本捕获 console 和异常，回传给 Agent。
   - 自动冒烟测试：帧在推进、画面非空白、模拟按键后状态有变化。
   - 截图交给模型做视觉检查。
   - 用 str_replace 增量修复，最多重试 3 次。

   这是 Claude Code Desktop、Dyad、llamacoder 的共同做法。

5. **对外协议对齐 MCP Apps**（SEP-1865，2026 年已成为 MCP 官方扩展，ChatGPT、Claude、VS Code、Goose 都已支持）。生成的应用与宿主之间的桥接 API 用 JSON-RPC，方法命名尽量沿用 MCP Apps。好处有两个：将来 AgentOS 能直接运行第三方 MCP App，自己生成的应用也能导出给 Claude 或 ChatGPT 使用。

---

## 1. 需求拆解

| 需求 | 技术含义 |
|---|---|
| 右侧对话，左侧即时出现应用或游戏 | 流式生成；运行时能毫秒级加载新代码；对话状态和应用状态联动 |
| 不重新编译 App | 生成物必须是**解释执行**的代码或数据（JS/HTML、声明式 DSL 等），不能是 Swift 源码 |
| 能做游戏（贪吃蛇、俄罗斯方块、坦克大战） | 需要 60fps 渲染循环、Canvas/WebGL、键盘和手柄输入、音频；最好离线可用 |
| 「OS」感 | 应用可保存、可再次打开、有版本可回滚、可多开；应用可以调用系统能力和 AI，并受权限控制 |
| 安全 | 生成的代码不可信：要隔离网络、隔离存储、限制桥接 API；死循环不能拖垮宿主 |

由此得出的核心问题有三个：

- **Runtime**：用什么运行时承载任意生成代码，同时快、强、安全。
- **Agent**：怎样稳定地生成能跑的应用，并能自我修复。
- **Contract**：宿主、Agent、生成应用三方之间的接口约定。

---

## 2. 业界参考：谁在做「AI 即时生成可运行应用」

### 2.1 厂商产品

| 产品 | 机制（重点看怎么运行生成物） | 对我们的意义 |
|---|---|---|
| **Claude Artifacts** | 单文件 HTML/React，放在独立域名的沙箱 iframe 里，配严格 CSP；库只能从白名单 CDN 加载，不能访问外网（[Willison 2024](https://simonwillison.net/2024/Oct/21/claude-artifacts/)）。2026 年起可在应用内调用 Claude、每个应用有存储、可连接外部应用（[帮助中心](https://support.claude.com/en/articles/9487310-what-are-artifacts-and-how-do-i-use-them)） | **直接照抄的模式**：单文件 + 固定库白名单 + 应用内 AI 桥 + 每应用一份存储 |
| **Imagine with Claude** | 2025-09 随 Sonnet 4.5 推出的限时研究预览，「即时生成软件，没有预先写好的功能」（[Anthropic](https://www.anthropic.com/news/claude-sonnet-4-5)）。实现机制未公开 [未核实] | 和 AgentOS 体验最接近。测试者反馈的弱点是**不能持久保存、按钮常常没接上逻辑**（[DataCamp](https://datacamp.com/tutorial/imagine-with-claude)），我们的设计要专门补上这两点 |
| **Gemini Dynamic View**（2025-11） | Gemini 3 Pro + 工具（生图、搜索）+ 很长的系统指令 + 后处理器，输出 HTML/CSS/JS，**明确包括游戏和模拟**（[Google Research](https://research.google/blog/generative-ui-a-rich-custom-visual-interactive-user-experience-for-any-prompt/)） | 印证了「详尽的规格型系统提示 + 自动修正」这条流水线 |
| **OpenAI Apps SDK** | ChatGPT 已直接实现 MCP Apps：iframe + postMessage 桥 + 由应用声明 CSP 域名（[OpenAI](https://developers.openai.com/apps-sdk/mcp-apps-in-chatgpt)） | 说明 MCP Apps 已成为跨厂商标准 |
| **v0 / Lovable** | 云端 microVM 或沙箱里跑 Vite dev server；Lovable 的预览中位时间正从 17.4s 降到 8.0s（[Lovable](https://lovable.dev/blog/faster-previews-oj)） | **反面参考**：「秒级启动 + 依赖云端」不符合「即时」 |
| **Google Disco / GenTabs**（2025-12） | 基于 Chromium 的实验浏览器，Gemini 用当前打开的标签页拼出小应用（[9to5Google](https://9to5google.com/2025/12/11/google-disco-gentab-browser/)） | 产品形态参考 |

### 2.2 协议与标准

| 协议 | 现状（2026-10） | 机制 | 建议 |
|---|---|---|---|
| **MCP Apps**（SEP-1865，扩展 ID `io.modelcontextprotocol/ui`） | 稳定版规范 2026-01-26，2026-07-28 MCP 发布中成为官方扩展（[规范](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx)，[ext-apps](https://github.com/modelcontextprotocol/ext-apps) Apache-2.0，约 3k★） | 以 `ui://` 资源（`text/html;profile=mcp-app`）的形式下发；宿主放进沙箱 iframe；用 `_meta.ui.csp` 声明 `connectDomains` 等；JSON-RPC over postMessage，方法包括 `ui/initialize`、`tools/call`、`ui/notifications/tool-input-partial`（流式输入）、`ui/update-model-context`、`ui/request-display-mode` | **对齐**。桥接 API 采用它的语义，P3 阶段兼容运行第三方 MCP App |
| **mcp-ui** | Apache-2.0，5.2k★，已改为实现 MCP Apps；`@mcp-ui/client` 的 `AppRenderer` 是推荐的宿主端 SDK | — | 如果宿主内部用 Web 渲染，可以直接复用 |
| **A2UI**（Google） | v0.9.1，v1.0 处于 RC，16.7k★ | 扁平的声明式 JSON 组件列表，只从宿主自己的可信组件目录渲染，不执行任何代码；官方渲染器有 Lit / Angular / Flutter / React，SwiftUI 只有社区实现 | **可选**。适合表单、设置类应用的原生渲染，**表达不了游戏** |
| **AG-UI**（CopilotKit） | MIT，16.5k★；约 16 种事件，走 SSE/WS；**没有 Swift SDK** | Agent ↔ 前端的事件流协议 | 只有把 Agent 拆成远端服务时才需要 |
| json-render（Vercel Labs）/ OpenUI Lang（Thesys） | 都很活跃 | Zod 组件目录 / 紧凑的流式 UI 语言 | 和游戏场景关系不大 |
| Vercel AI SDK `streamUI`（RSC） | 官方标注实验性，「不建议生产使用」 | — | 不采用 |

### 2.3 值得研究的开源实现

| 项目 | 规模 / 许可 | 借鉴点 |
|---|---|---|
| [llamacoder](https://github.com/Nutlope/llamacoder) | 7.1k★ MIT | **最贴近我们的模式**：已从 Sandpack 换成浏览器内 esbuild-wasm；import map 指向预构建的本地库；沙箱 iframe；构建和运行错误回传给 LLM 做「Try to fix」（[architecture.md](https://github.com/Nutlope/llamacoder/blob/main/architecture.md)） |
| [Dyad](https://github.com/dyad-sh/dyad) | 21.9k★ Apache-2.0（`src/pro` 为 FSL） | 本地版 Lovable：`search_replace` 和 `write_file` 的选用规则；`read_logs` / `restart_app` 工具；预览区内的 postMessage 截图；**应用生成基准测试** |
| [bolt.diy](https://github.com/stackblitz-labs/bolt.diy) | 19.9k★ MIT | 可增量解析的 `<boltArtifact>` 流式协议；「预览报错 → 让 Bolt 修」按钮。注意：**WebContainers 商用要付费授权**（[StackBlitz](https://webcontainers.io/enterprise)），且它只会整文件重写，这两点都不要学 |
| [open-lovable](https://github.com/firecrawl/open-lovable) | 28.7k★ MIT | 流式生成进沙箱；fast-apply 增量编辑 |
| [e2b fragments](https://github.com/e2b-dev/fragments) | 6.4k★ Apache-2.0 | 「fragment」结构（template / files / dependencies）；多模型支持 |
| [Cline](https://github.com/cline/cline) | 70k★ Apache-2.0 | 每次浏览器操作后返回「截图 + console 日志」的闭环 |
| [pi-generative-ui](https://github.com/Michaelliv/pi-generative-ui) + [glimpse](https://github.com/HazAT/glimpse) | 1.2k★（无许可，只能学习）/ 974★ MIT | **macOS 原生**：把流式 HTML 小组件放进 WKWebView 窗口，配双向 JSON 桥。和我们的形态非常接近 |
| Claude Code Desktop 的浏览器面板 | 产品 | 默认开启 `autoVerify`：每次编辑后自动截图、检查报错、确认后才结束本轮（[docs](https://code.claude.com/docs/en/desktop)）。是 AgentOS 闭环最好的样板 |
| 聊天应用里的 Artifacts（LibreChat / LobeHub / Open WebUI / Cherry Studio） | 45k–156k★ | 两种做法：Sandpack，或者 `srcdoc` iframe + 注入 CSP meta。已有测试证明沙箱 iframe 无法移除注入的 CSP（[Willison 2026](https://simonwillison.net/2026/Apr/3/test-csp-iframe-escape/)） |
| [Puter](https://github.com/HeyPuter/puter) | 43.7k★ AGPL | Web OS，2026-08 推出 AI Builder。**所有生成应用共用一套 SDK（puter.js）** 的思路值得借鉴 |
| [daedalOS](https://github.com/DustinBrett/daedalOS) | 13k★ MIT | 只能作为桌面外壳和窗口管理的参考 |
| wandesk / vibeOS / llm-os | < 100★ | 「每个窗口都按需生成」的概念验证，说明方向有人在做，但都不成熟 |

### 2.4 三种范式对比（针对游戏）

| 范式 | 代表 | 游戏能力 | 首屏速度 | 安全 | 结论 |
|---|---|---|---|---|---|
| **A1 单文件 HTML + 本地内置库 + 沙箱 WebView** | Artifacts、llamacoder、Websim | ✅ 完整 | **< 1s** | 好（沙箱 + CSP） | **默认方案** |
| A2 多文件 React，客户端编译 | Sandpack、esbuild-wasm | ✅ | 1–3s | 好 | 只在复杂工具类应用时启用 |
| A3 完整 dev server（WebContainer / 云 VM） | bolt、v0、Lovable | ✅ | 8–17s | 好 | ❌ 太慢，还依赖云端或要商业授权 |
| B 声明式组件协议 | A2UI、json-render | ❌ | 极快 | 最好 | 只用于表单、设置类 |

---

## 3. Runtime 层

### 3.1 候选对比

| 方案 | 启动 | 2D/3D 游戏 | 原生感 | 安全 | 工作量 | LLM 生成可靠度 |
|---|---|---|---|---|---|---|
| **Swift + WKWebView（AppKit 子类）** | 热 ~50ms / 首个 ~1.1s [实测] | Canvas、WebGL2、WebGPU、Web Audio、Gamepad | 外壳原生，内容是 Web | 独立进程 + CSP + 规则列表 + 每应用独立存储 | 低–中 | **最高**（Web 是 LLM 最熟悉的生态） |
| SwiftUI `WebView`/`WebPage`（macOS 26） | 同上 | 同上 | 同上 | 同上 | 低 | 同上，但**键盘控制更弱**（见 3.6） |
| JSContext + 自建原生渲染桥 | ms 级 | 要自己实现 Canvas、音频、输入 | 原生 | **和宿主同进程**；需要 `allow-jit` 授权 | **高** | 低（模型不认识自定义 API） |
| JSON/DSL → SwiftUI（A2UI） | ms 级 | ❌ | **最好** | 最好 | 中 | 写 UI 不错，做不了游戏 |
| Tauri 2 | 同 WKWebView | 同 WKWebView | Web | 能力 ACL 好 | 中（Rust） | 同上 |
| Electron | 慢、重 | 最全的 Web API | Web | 好 | 中 | 同上 |
| React Native macOS | 加载 bundle | 弱（默认没有 Canvas/WebGL） | 原生控件 | 同进程 | 高 | 中（离不开 Metro） |
| QuickJS / Lua / WasmKit | ms 级 | 要自己做渲染器 | 原生 | 同进程解释器 | 高 | 低–中 |
| `swiftc` 编译 + `dlopen` 加载 | 编译要数秒 | Metal / SpriteKit | **最好** | **最差**（不受沙箱约束的原生代码） | 中 | 中（编译错误多） |

**结论**：外壳用 SwiftUI，运行时用 **AppKit `WKWebView` 子类**，通过 `NSViewRepresentable` 嵌入。如果以后要跨平台，可以换成 Tauri 2，前端那层（运行时合约、内置库、shim）可以原样复用。

### 3.2 推荐的运行时设计

```
agentos://<appId>/index.html   ← 每个应用一个 host，即独立 origin
agentos://<appId>/assets/...
agentos://lib/phaser@3.x.min.js ← 本地内置、版本固定的库（离线可用）
```

- **虚拟文件系统**：`WKURLSchemeHandler` 从 `~/Library/Application Support/AgentOS/apps/<id>/` 读文件。每个响应都带 `Cache-Control: no-store` 和严格的 CSP 头。
- **网络隔离**：默认禁止联网，三层同时生效：
  - CSP：`default-src 'none'; script-src agentos: 'unsafe-inline'; connect-src agentos: …`
  - `WKContentRuleList`：拦截 `^https?://` 和 `^wss?://`。正则不支持 `(a|b)`，所以每个 scheme 写一条规则。
  - `WKNavigationDelegate`：只放行 `agentos:` 的导航；`createWebViewWith` 一律返回 nil。
  - 某个应用需要联网时，在 manifest 里声明 `connectDomains`，经用户授权后动态放宽 CSP。语义和 MCP Apps 一致。
- **存储隔离**：每个应用一个 `WKWebsiteDataStore(forIdentifier: appUUID)`（macOS 14+）[SDK + 实测]。删除应用时调用 `remove(forIdentifier:)`。
- **桥接**：用 `WKScriptMessageHandlerWithReply` 在 page world 注入 `window.agentos`。Swift 侧对**每条消息**都要检查：
  - `frameInfo.isMainFrame`
  - `securityOrigin` 是否等于 `agentos://<appId>`
  - 该应用是否已获得对应能力
  - 参数是否符合 schema
- **调试数据回传**：在 `.atDocumentStart` 注入脚本，包装 `console.*`、`error`、`unhandledrejection`，把文件名、行号、stack 回传给 Swift。这些就是 Agent 拿到的「运行日志」。
- **WebView 池**：App 启动时预热 1–2 个 WebView，因为第一个 WebView 冷启动约 1.1s，主要花在拉起 WebContent 和 GPU 进程。后台应用设置 `inactiveSchedulingPolicy = .suspend` 节省资源。

### 3.3 本机实测数据（macOS 26.5.1，M5 Pro，WebKit 26.5）

| 项 | 结果 |
|---|---|
| `agentos://` 是安全上下文 | ✅ `isSecureContext === true`，`crypto.subtle` 可用 |
| WebGPU / WebGL2 / ES Module / import map / Blob import / IndexedDB | ✅ 全部可用 |
| 启动 | 进程内第一个 WebView ~1.1s；**第二个（热）46ms；`reload()` 4–6ms**；SwiftUI `WebPage` 230ms |
| rAF 帧率 | 在 120Hz 内建屏上**约 60fps（WebKit 有上限）**，游戏必须用 delta-time 计时 |
| JS 性能（fib(30) + 循环） | WKWebView 102ms；开启 macOS 26.5 新增的 `securityRestrictionMode=.maximizeCompatibility`（会关 JIT）后 553ms；JSContext 无 JIT 624ms，有 `allow-jit` 112ms |
| 不加 CSP 时 | ⚠️ CDN `import()`、`<img>`、no-cors `fetch`、WebSocket **全部能出网**；加 CSP 头或规则列表后全部拦截 |
| iframe 与桥接 | ⚠️ `sandbox="allow-scripts"` 的 iframe（origin 为 null）**仍能调用 `webkit.messageHandlers`**，必须在 Swift 侧校验 frameInfo |
| 截图 | ✅ `takeSnapshot` 能截到 WebGL 画布像素，可用于视觉校验和「画面非空白」检测 |
| 音频 | ✅ macOS 上 `AudioContext` 无需用户手势即可 `resume()` |
| 死循环 | ⚠️ `while(true){}` 不会卡住宿主，但 **WKWebView 释放后 WebContent 进程仍占满 CPU 12s 以上**，没有公开的 kill API |
| SwiftUI `WebPage` | 支持 `urlSchemeHandlers`、`websiteDataStore`、`userContentController`（所以**能**做 JS→Swift 桥），也支持 `callJavaScript` 和 `exported(as: .image())`。但**没有 `WKPreferences`，也不能子类化** |

### 3.4 生成物的形态和库选择

- **默认是单文件 `index.html`**，内联 JS/CSS，没有构建步骤。超过约 800 行时拆成 ES Module 多文件，仍然不需要构建。
- **库全部内置在本地，版本固定，通过 import map 引入**。不用 CDN：离线可用，避开供应链风险，也让 CSP 保持严格。
- **TSX/JSX 只在必要时编译，而且在宿主侧做**，用 sidecar 里 Bun 自带的 transpiler 或 esbuild。这样 CSP 不用开 `unsafe-eval` 和 `blob:`，浏览器内的 esbuild-wasm 和 Babel standalone 都需要这两项。DOM 类工具应用优先用 **Preact + htm**，完全不需要编译。
- **游戏库白名单**（以下是判断，P1 用评测集验证）：

  | 场景 | 选择 | 说明 |
  |---|---|---|
  | 简单 2D（贪吃蛇、俄罗斯方块、2048、扫雷） | **原生 Canvas 2D** | 零依赖，LLM 最稳 |
  | 较复杂 2D（坦克大战、平台跳跃、射击） | **Phaser 3.x（固定版本）** | Phaser 4 已于 2026-04 发布，但模型训练数据以 v3 为主 |
  | 3D | **three.js**（固定版本） | `WebGPURenderer` 可回退到 WebGL2 |
  | 物理 | Matter.js | — |
  | 音效 | 原生 Web Audio 合成 | 不需要素材文件 |
  | 默认不用 | PixiJS v8、Kaplay（v4000 还是 alpha）、p5 2.x | 模型常写成旧版 API（异步 init、1.x/2.x 分裂） |

  为每个库附一张简短的「API 卡片」，放进 Skill，减少版本漂移。
- **美术素材**：先让模型用 Canvas/SVG 程序化绘制。坦克大战的砖墙、坦克、子弹都可以直接画出来。以后再接图像生成模型做 sprite。

### 3.5 热更新策略

1. **默认：整页 reload + 状态交接**。reload 前调用 `callAsyncJavaScript("return window.__agentos?.saveState?.()")`，reload 后用 document-start 脚本把状态注回去。reload 本身约 5ms。
2. **模块热替换**：约定入口为 `export function mount(root, prevState)` 和 `export function unmount(): State`，宿主执行 `import('./game.js?v=N')` 替换，不用刷新页面。
3. **双缓冲**：在隐藏的热 WebView 里加载新版本，就绪后再切换显示。新版本报错时自动回滚到上一个能用的版本，用户看不到坏掉的中间态。

### 3.6 已知坑

- **键盘**：
  - 方向键和空格会触发系统「咚」声，需要子类重写 `performKeyEquivalent`。
  - 加载完成和点击时要 `makeFirstResponder`，shim 里对方向键和空格 `preventDefault`。
  - 手柄输入只会送到 key window 里处于 first responder 的 WebView。
  - 这三点就是不直接用 SwiftUI `WebView` 的原因。
- **死循环**：
  - 服务时对代码做循环保护转换（类似 CodePen 在循环里插时间守卫）。
  - 加 watchdog 心跳。
  - UI 上提供「重启运行时」。
- **跨 host 请求**：不同自定义 scheme host 之间的 fetch 受限（WebKit bug 199064，修复只以 SPI 形式存在），所以每个应用的文件要放在自己的 origin 下。
- **WebKit 版本跟随系统**：用户机器上的 WebKit 版本决定可用能力。对 `navigator.gpu` 做特性检测，并回退到 WebGL2。
- **不要**给游戏视图开 `securityRestrictionMode` 或锁定模式，JS 会慢约 5 倍。

---

## 4. Agent 层

### 4.1 引擎选项

| 引擎 | 版本 / 许可 | 接入方式 | 评价 |
|---|---|---|---|
| **Claude Agent SDK（TS）** | `@anthropic-ai/claude-agent-sdk` 0.3.x，Anthropic 商业条款 | sidecar（stdio） | **首选**：本质是把 Claude Code 打包成库，内置 Read/Write/Edit/Glob、hooks、会话、子 Agent、Skills、MCP |
| Swift 原生循环 + Messages API | 没有官方 Swift SDK，用 URLSession + SSE，或 [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel)（Apache-2.0，多厂商） | 进程内 | **备选**：约 10 个工具，自写循环几百行；没有 Node 依赖，体积小，适合 App Store |
| pi coding agent | MIT，多厂商，有 RPC 模式 | sidecar | 多模型时的强力备选 |
| Vercel AI SDK 7 | Apache-2.0 | sidecar | TS 里最好的多厂商工具循环 |
| OpenAI Agents SDK / Codex app-server | MIT / Apache-2.0 | sidecar | 以 OpenAI 为主时考虑 |
| opencode / Goose（支持 ACP） | MIT / Apache-2.0 | ACP | 偏重，可通过 ACP 接入 |
| Apple Foundation Models | 系统框架 | 进程内 | 端上上下文只有 **4096 token**（输入输出共享），**不够生成游戏**。适合意图路由、起应用名、填 manifest |
| Ollama / MLX（本地模型） | — | `ANTHROPIC_BASE_URL` 指向 Ollama（≥0.14 兼容 Anthropic Messages API） | 作为低质量、离线、免费的档位 |

### 4.2 推荐：Claude Agent SDK sidecar

```
Swift Host ──Process(stdin/stdout, NDJSON JSON-RPC)──▶ agent-engine (Bun 编译的单文件)
                                                         └─ query({ cwd: apps/<id>, tools: [Read,Write,Edit,Glob],
                                                                    mcpServers: { runtime: createSdkMcpServer(...) },
                                                                    hooks: { PreToolUse: 路径白名单, PostToolUse: 自动运行+冒烟 },
                                                                    includePartialMessages: true, resume: sessionId })
         ◀── rpc/call runtime.run_app / screenshot / smoke_test ...（Swift 操作 WKWebView 后返回结果）
```

- **进程模型**：`query()` 会拉起 SDK 自带的原生 `claude` 二进制，用 stdio 通信，每个会话一个子进程。要求 Node ≥ 18 或 Bun（[hosting 文档](https://code.claude.com/docs/en/agent-sdk/hosting)）。
- **打包**：用 `bun build --compile` 打成单文件。启动时把内置的 claude 二进制释放到真实路径，再通过 `pathToClaudeCodeExecutable` 传进去。darwin-arm64 的二进制包解压后**约 248MB**，会显著增大 App 体积。
- **限权**：
  - 只开 `Read / Write / Edit / Glob`，不开 Bash 和 Web。
  - `cwd` 设为应用目录，`settingSources: []`。
  - 加 `PreToolUse` hook，拦截所有越出应用目录的路径。
- **流式**：开 `includePartialMessages: true`，Write 工具的入参会以增量形式流过来，右侧可以实时显示「正在写代码」。
- **授权（重要）**：Agent SDK 的文档说明，**未经 Anthropic 批准，第三方产品不得提供 claude.ai 登录**。所以只能让用户自带 API Key（存 Keychain），或者自建代理（`ANTHROPIC_BASE_URL`）。品牌上可以写「Powered by Claude」，不能叫「Claude Code」（[overview](https://code.claude.com/docs/en/agent-sdk/overview)）。
- **预留替换**：Host ⇄ Engine 协议按 [ACP](https://agentclientprotocol.com/protocol/session-setup) 的形状设计（`session/new` 可以注入 `mcpServers`）。以后可以换成 `claude-agent-acp`、`codex-acp`、`opencode acp`、`goose acp`，或者 Swift 原生循环，宿主 UI 不用改。

### 4.3 模型选择（取自 Anthropic 官方模型表，缓存日期 2026-10-06）

| 用途 | 模型 ID | 价格（输入 / 输出，$/MTok） | 备注 |
|---|---|---|---|
| **新建应用、复杂游戏（默认）** | `claude-opus-5-5` | 4 / 20（缓存读 0.20） | effort 默认 `medium`，要显式设置；简单游戏可用 low/medium，坦克大战这类用 high |
| 极难任务 | `claude-fable-5-1` | 10 / 50 | 一般用不到 |
| 小改动、修 bug（需实测） | `claude-sonnet-5-5` | 2 / 10 | — |
| 路由、起名、生成 manifest | `claude-haiku-5-5` | 0.10 / 0.50（≤100K） | 也可以用端上 Foundation Models |

- **先测再分流**：先测「一个 Opus 5.5，每轮调 effort」，再决定要不要做多模型级联。提示词缓存按模型隔离，跨模型切换会损失缓存命中，单次请求更便宜不等于任务总成本更低。
- **API 注意事项**（Opus 5.5 / Sonnet 5.5）：
  - 强制 `tool_choice: any/tool` 会返回 400，要用 `auto` 加提示词引导。
  - Opus 5.5 不能关闭 thinking，只能靠 effort 控制。
  - 对话历史要保持 append-only，否则 thinking 块会失效。
  - 自写循环时，写文件类工具开 `eager_input_streaming: true` 让代码边生成边流出，并且要自己校验不完整的 JSON。
- **粗估成本**（未实测）：新建一个中等复杂度的游戏，输出（代码 + thinking）约 15–40K token，输入大部分命中缓存，每个应用约 **$0.5–1.5**；一次小修改在几美分到十几美分。P0 阶段要实测。

### 4.4 工具集

文件工具直接用 SDK 内置的 Read / Write / Edit / Glob，作用范围限定在 `apps/<id>/`。

运行时工具以 MCP 工具的形式注册（在 Agent 侧显示为 `mcp__runtime__*`），由 Swift 实际执行：

```ts
run_app(reset_state?: bool) -> { loaded, load_ms, errors: ConsoleEntry[] }
get_console(since_seq?: int, levels?: ("error"|"warn"|"log")[], limit=50) -> ConsoleEntry[]
smoke_test(duration_ms=3000, inputs?: InputStep[],
           checks?: ("no_errors"|"frames_advancing"|"canvas_nonblank"|"state_changes")[])
  -> { pass, failures[], fps, screenshot_id }
send_input(steps: {type:"keydown"|"keyup"|"click"|"wait", key?, x?, y?, ms?}[]) -> { console_delta, state? }
screenshot(max_px=1024) -> image            // 用于视觉校验
inspect_state() -> JSON                     // 返回应用通过 agentos.expose() 暴露的状态
save_app(title, icon?, description?) -> { app_id, version }
list_apps(query?) / open_app(app_id) / revert_app(app_id, version)
```

`ConsoleEntry` 的结构是 `{seq, level, msg, file, line, stack}`。

### 4.5 生成 → 验证 → 修复闭环

1. **路由**：用 Haiku 5.5 或端上模型判断请求属于新建、修改还是提问，并选模板 Skill（canvas-game / phaser-game / three-3d / dom-tool / dashboard）。
2. **脚手架**：宿主把模板（包含 `agentos.js` shim）复制到 `apps/<id>/`，`git init` 并提交 v0。左侧立即切换到一个预热好的空白 WebView。
3. **生成**：Opus 5.5 写 `index.html`。工具入参流式到达，右侧实时显示代码；每次写完后防抖 reload 左侧预览。
4. **自动验证**：`PostToolUse` hook（或模型自己）调用 `run_app` 再调 `smoke_test`，检查四项：
   - 没有未捕获的异常或 rejection。
   - rAF 帧在推进。
   - canvas 不是空白，而且 0.5s 和 2.5s 的截图有差异。
   - 模拟方向键后，`agentos.expose()` 暴露的状态有变化。
5. **回传**：把失败信息压缩成摘要回给模型：去重后的错误、栈顶帧、文件和行号，总长不超过约 2K token。
6. **修复**：用 Edit（str_replace）增量修改。规则如下：
   - 每轮最多 3 次。
   - 同一个错误签名出现两次就停下并报告，或提高 effort。
   - str_replace 连续失败两次就改为整文件重写（Dyad 的规则）。
7. **视觉校验**：只对新建的应用做一次。把截图发给模型，问「这是一个可玩的俄罗斯方块吗？列出视觉缺陷」。
8. **提交**：git commit 一个新版本，更新 `manifest.json`，把 `session_id` 和 `app_id` 关联起来。
9. **用户报 bug**：自动附上最近的 console 缓冲区和当前截图。

### 4.6 系统提示与 Skills

- **运行时合约**（写进系统提示，保持稳定以便缓存）：
  - 应用是单文件 HTML，不能联网。
  - 库只能来自白名单，用 import map 引入。
  - 画布铺满视口，并处理 `devicePixelRatio` 和 resize。
  - 游戏用 delta-time 计时。
  - 必须调用 `agentos.expose(state)`，并实现 `onPause` / `onResume` / `saveState`。
- **Skills（按应用类型的模板）**：每类包含一个已验证可用的示例（比如完整的贪吃蛇）、库的 API 卡片和常见坑。通过 Agent SDK 的 `plugins` / skills 从本地目录加载。
- **提示词缓存顺序**：tools → system → 合约 → skill → 对话。Agent SDK 会自动缓存。

---

## 5. 整体架构

```
┌──────────────────────────── AgentOS.app（Swift / SwiftUI）────────────────────────────┐
│ ┌──────────── 左：App Canvas ─────────────┐ ┌──────────── 右：Chat ───────────────┐ │
│ │ GameWebView（WKWebView 子类，每应用一个）  │ │ 消息流 / 工具调用卡片 / 流式代码      │ │
│ │  agentos://<appId>/index.html            │ │ 版本时间线 / 撤销 / 截图与报错附件    │ │
│ │  + agentos.js shim（桥接 / console / expose）│ │                                      │ │
│ └──────────────────────────────────────────┘ └──────────────────────────────────────┘ │
│  Dock / 启动台：已保存应用列表、多开、弹出到独立窗口                                     │
├──────────────────────────────────── Host Core（Swift）─────────────────────────────────┤
│ AppRegistry  manifest + 每应用一个 git 仓库（版本 / 回滚）                                │
│ VFS          WKURLSchemeHandler：agentos://<appId>/…、agentos://lib/…（内置库）          │
│ RuntimeMgr   WebView 预热池、状态交接、双缓冲、watchdog、per-app WKWebsiteDataStore     │
│ Bridge       JSON-RPC（语义对齐 MCP Apps）、frame / origin 校验、能力授权                │
│ AgentClient  拉起 sidecar、stdio JSON-RPC、运行时工具的 RPC 执行、会话映射               │
│ Secrets      Keychain 存 API Key（生成的应用永远拿不到）                                │
├──────────────────────── agent-engine（sidecar，Bun 编译的单文件）───────────────────────┤
│ Claude Agent SDK：query() + Read/Write/Edit/Glob + MCP "runtime" + hooks + skills       │
└──────────────────────────────────────────┬────────────────────────────────────────────┘
                                           │ HTTPS
                       Anthropic API（Opus 5.5 / Sonnet 5.5 / Haiku 5.5）｜ 本地 Ollama（可选）
```

### 5.1 一次「做个贪吃蛇」的时序

```
用户 ─▶ Chat：「做个贪吃蛇」
Host ─▶ AppRegistry.create(template: canvas-game) → apps/a1b2/（git v0）→ 左侧切到预热好的 WebView
Host ─▶ Engine：session/prompt { appId: a1b2, text }
Engine ─▶ Claude：系统提示 + 运行时合约 + skill(canvas-game)
Claude ─▶ Write(index.html) …… 入参流式 ──▶ Host：右侧实时显示代码
Engine(PostToolUse) ─▶ Host：runtime.run_app → reload(~5ms) → console 摘要
Claude ─▶ smoke_test(3s, ←↑→↓) ─▶ Host：{ pass:false, errors:[TypeError … line 88] }
Claude ─▶ Edit(index.html, old→new) ─▶ run_app ─▶ smoke_test：pass ✅
Claude ─▶ screenshot ─▶ 视觉自检：OK
Host ─▶ git commit v1、更新 manifest ─▶ Chat：「已完成，方向键控制，空格暂停」
```

### 5.2 目录与清单

```
~/Library/Application Support/AgentOS/
├── apps/<appId>/
│   ├── manifest.json        # 见下
│   ├── index.html           # 入口（默认单文件）
│   ├── assets/
│   └── .git/                # 版本历史
├── lib/                     # 内置库（Phaser、three.js、Matter.js、Preact+htm …）+ api-cards/
├── skills/                  # 应用类型模板
├── sessions/                # CLAUDE_CONFIG_DIR，会话转录与恢复
└── settings.json
```

```jsonc
// manifest.json
{
  "id": "a1b2…", "title": "贪吃蛇", "icon": "🐍", "entry": "index.html",
  "runtimeVersion": 1,                       // 运行时合约版本，便于以后升级
  "permissions": { "network": [], "ai": false, "notifications": false, "clipboard": false },
  "versions": [{ "v": 1, "commit": "…", "summary": "初版", "at": "…" }],
  "sessionId": "…", "model": "claude-opus-5-5", "created": "…", "updated": "…"
}
```

### 5.3 运行时合约：生成应用可用的 `window.agentos`

```ts
interface AgentOS {
  app: { id: string; version: number };
  // 生命周期与热更新
  onPause(cb: () => void): void;
  onResume(cb: () => void): void;
  saveState(fn: () => unknown): void;       // reload 前由宿主调用
  restoredState(): unknown | undefined;     // reload 后取回
  // 供 Agent 测试与理解
  expose(state: object | (() => object)): void;   // 对应 inspect_state / smoke_test
  updateModelContext(ctx: object): void;    // 对齐 MCP Apps 的 ui/update-model-context，如「当前分数 120」
  // 能力（按 manifest.permissions 授权）
  storage: { get(key: string): Promise<unknown>; set(key: string, v: unknown): Promise<void> };
  ai?: { complete(prompt: string, opts?: object): Promise<string> };  // 宿主代理调用，有配额
  notify?(title: string, body?: string): Promise<void>;
  files?: { openPicker(opts?): Promise<File>; save(name: string, data: Blob): Promise<void> };
}
```

底层统一用 JSON-RPC 2.0（`{jsonrpc, id, method, params}`），方法名能对齐 MCP Apps 的就对齐（`ui/initialize`、`tools/call`、`ui/update-model-context`、`ui/request-display-mode`）。

---

## 6. 安全模型

| 威胁 | 措施 |
|---|---|
| 生成代码偷偷联网、外传数据 | CSP 默认 `connect-src agentos:`；`WKContentRuleList` 拦截 http(s) 和 ws(s)；导航白名单；按应用授权联网域名 |
| 应用之间互相读数据 | 每个应用独立 origin（`agentos://<appId>`）+ 独立 `WKWebsiteDataStore` |
| 通过 iframe 或注入调用桥接 | Swift 侧校验 `isMainFrame` 和 origin；能力白名单；参数 schema 校验 |
| 拿到用户的 API Key | Key 只存在 Keychain 和 sidecar 进程环境里；`agentos.ai` 由宿主代理，带配额 |
| Agent 越权读写文件 | 只开放文件工具；`cwd` 限定在应用目录；`PreToolUse` hook 做路径白名单；不开 Bash |
| 死循环、内存爆炸 | 循环保护转换、watchdog、「重启运行时」、`webViewWebContentProcessDidTerminate` 后自动恢复 |
| App 沙箱 | 宿主需要 `network.client` 来调 LLM，所以 App Sandbox 挡不住 WebView 联网，网络隔离只能靠上面几层 |

---

## 7. 路线图

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| **P0 技术验证**（1–2 周） | SwiftUI 左右分栏；GameWebView + scheme VFS + CSP；Agent SDK sidecar（stdio）；Write → reload；console → Agent | 一句话生成**贪吃蛇和俄罗斯方块**并能玩；宿主零重编译；记录首次可玩时间（TTFP）和单次成本 |
| **P1 MVP**（3–4 周） | 应用注册表 + git 版本 + 撤销；流式代码视图；`smoke_test` / `send_input` / `screenshot` / 自动修复闭环；4 类 Skill 模板；`agentos.storage` + 热更新状态交接；**评测集**（10 个经典游戏：贪吃蛇、俄罗斯方块、坦克大战、打砖块、2048、扫雷、Flappy、太空侵略者、乒乓、迷宫） | 评测集一次通过率、平均 TTFP、每个应用成本可度量并持续优化 |
| **P2 「OS」化** | Dock / 启动台、多开、弹出独立窗口；权限管理 UI；`agentos.ai`；按应用授权联网；导出单文件 HTML；本地模型（Ollama）；模型路由 | — |
| **P3 生态** | 兼容 MCP Apps（运行第三方 MCP App，或把 AgentOS 应用导出为 MCP App）；A2UI 原生渲染表单类应用；分享 | — |

---

## 8. 风险与待决问题

1. **分发渠道**：要不要上 Mac App Store？
   - Agent SDK sidecar（约 248MB，需要拉起子进程）能否在 App Sandbox 下运行 [未核实]。
   - 如果要上架，Agent 层改用 Swift 原生循环。
2. **账号与计费**：claude.ai 登录不能用于第三方产品，只有两条路：
   - 用户自带 API Key（BYOK）。
   - 自建代理后端（自己承担成本、自己收费）。
3. **生成延迟**：复杂游戏要生成数千到上万 token 的代码，耗时在数十秒量级。可以从这几方面缓解：
   - 流式展示代码和预览。
   - 从已验证的模板起步，减少需要生成的量。
   - 简单应用降低 effort。
   - Opus 5.5 fast mode（输出最快 2.5 倍，价格 2 倍）。
4. **复杂游戏质量**：坦克大战涉及地图、敌人 AI、碰撞、关卡，一次生成成功率不确定。依赖 Skills 模板、拆多文件、视觉校验，并用评测集持续度量。
5. **WebKit 版本跟随用户系统**：需要特性检测和降级。
6. **跨平台需求**：如果将来要支持 Windows，就把外壳换成 Tauri 或 Electron，前端运行时层（合约、shim、内置库）原样复用。
7. **[未核实] 项**：
   - Claude Artifacts 当前的 CSP 白名单。
   - Imagine with Claude 和 Websim 的内部机制。
   - WWDC26 的 Foundation Models 第三方 Provider 和 PCC 能否在 macOS 26.5 上使用。
   - MCP 2026-07-28 正式版规范与 RC 是否一致。

---

## 9. 参考资料

- MCP Apps 规范：https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx
- MCP 2026-07-28 发布：https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/
- OpenAI Apps SDK × MCP Apps：https://developers.openai.com/apps-sdk/mcp-apps-in-chatgpt
- A2UI：https://github.com/a2ui-project/a2ui ｜ 渲染器：https://a2ui.org/ecosystem/renderers/
- AG-UI：https://github.com/ag-ui-protocol/ag-ui ｜ CopilotKit 生成式 UI：https://docs.copilotkit.ai/learn/generative-ui
- Google 生成式 UI：https://research.google/blog/generative-ui-a-rich-custom-visual-interactive-user-experience-for-any-prompt/
- Claude Agent SDK：https://code.claude.com/docs/en/agent-sdk/overview ｜ 部署：https://code.claude.com/docs/en/agent-sdk/hosting ｜ TS 参考：https://code.claude.com/docs/en/agent-sdk/typescript
- Agent Client Protocol：https://agentclientprotocol.com/protocol/session-setup ｜ claude-agent-acp：https://github.com/agentclientprotocol/claude-agent-acp
- Ollama Anthropic 兼容：https://docs.ollama.com/api/anthropic-compatibility
- WebKit in Safari 26.0：https://webkit.org/blog/17333/webkit-features-in-safari-26-0/
- WKWebsiteDataStore：https://developer.apple.com/documentation/webkit/wkwebsitedatastore
- 自定义 scheme CORS：https://bugs.webkit.org/show_bug.cgi?id=199064
- WKWebView 按键提示音：https://developer.apple.com/forums/thread/748152
- WebContainers 商业授权：https://webcontainers.io/enterprise
- llamacoder 架构：https://github.com/Nutlope/llamacoder/blob/main/architecture.md
- Dyad：https://github.com/dyad-sh/dyad ｜ bolt.diy：https://github.com/stackblitz-labs/bolt.diy ｜ open-lovable：https://github.com/firecrawl/open-lovable
- glimpse：https://github.com/HazAT/glimpse ｜ pi-generative-ui：https://github.com/Michaelliv/pi-generative-ui
- Phaser releases：https://github.com/phaserjs/phaser/releases ｜ three.js WebGPURenderer：https://threejs.org/manual/en/webgpurenderer
