# 04 应用包、构建与生命周期

> 所属：[技术方案总览](README.md) ｜ 相关：[00 内核](00-kernel.md)、[03 运行时](03-app-runtime.md)、[05 协议](05-app-protocol.md)、[09 安全](09-security.md)、[10 工作间 VM](10-workbench-vm.md)
>
> 依据：[system-architecture.md](../research/system-architecture.md) 第 3 节、[tech-assessment.md](../research/tech-assessment.md) 第 3.12 节

## 1. 职责

定义应用的结构和统一的包格式，并管理应用从诞生到卸载的全过程：创建、构建、校验、安装、升级、回滚、卸载、导出。三类产物共用同一套结构和安装流程。

## 2. 应用的结构

每个应用的源码树（Builder 的工作目录，一个 git 仓库）：

```
apps/<id>/src/
├── manifest.json            # 清单（第 3 节）
├── interface/
│   ├── interface.json       # 接口定义，接口的真相源（05）
│   └── schemas/             # 应用私有的类型（可选）
├── core.js                  # 无界面核心：工具、订阅、数据逻辑（03 第 4 节）；大了可以拆成 core/ 下的模块
├── ui/
│   └── index.html           # 界面；大了再拆成 ES 模块
├── tests/
│   ├── contract.json        # 契约测试（05 第 13 节）
│   └── smoke.json           # 冒烟测试的输入步骤和检查项
├── SKILL.md                 # 给 Agent 看的使用说明：什么时候用这个应用、常见用法
└── SPEC.md                  # 应用规格说明：用途、关键设计决定、已知问题；Builder 每次修改后更新
```

B 类原生应用把 `core.js` 和 `ui/` 换成 Swift 源码（`Sources/`），由宿主编译成 `.app`（第 5.2 节）。

## 3. 清单 `manifest.json`

```jsonc
{
  "schema": "agentos.app/1",
  "id": "3f2a9c4e-1b7d-4e8a-9c21-5d6f7a8b9c0d",   // 宿主分配的 UUID，稳定不变；原生应用的 bundle id 由它派生
  "version": "1.4.0+27",                           // 语义化版本 + 递增的构建号（第 7 节）
  "title": "待办", "icon": "✅",
  "runtime": { "kind": "web",                       // web | macos-native | wasm-component | oci
               "core": "core.js", "ui": "ui/index.html",
               "minHost": "26.0" },
  "interface": { "path": "interface/interface.json", "digest": "sha256:…" },
  "permissions": {                                  // 申请的能力，安装时转成能力授权（09 第 5 节）
    "network": [], "services": [], "files": [] },   // 数据集合、订阅、调用写在 interface.json 里
  "agent": { "sessionId": "…", "model": "claude-opus-5-5" },
  "update": { "previous": "1.3.2+26", "dataSchema": null },
  "source": { "recipe": "none" },                   // none | swiftc | swiftpm | cargo-component | containerfile
  // 以下字段在导出和 C 类构建时才有（P4）
  "artifacts": [], "provenance": null, "signature": null
}
```

- 清单和接口都由 Builder 编写，宿主在安装时校验；宿主不信任清单里的任何「授权」，只把它当申请。
- P1a 不做签名：签名者和校验者是同一台机器上的同一个宿主，意义不大。签名和构建证明只在导出、导入和 C 类构建时使用（第 8 节）。

## 4. 磁盘布局与迁移

```
~/Library/Application Support/AgentOS/
├── apps/<id>/
│   ├── src/                 # 源码工作区（git 仓库）；Builder 在这里改代码
│   ├── versions/<ver>/      # 已安装的各个版本，不可变
│   └── current -> versions/<ver>
└── system/                  # 宿主私有（00 第 9 节）：kernel.sqlite、data/、bus.sqlite、meta/、agent/、logs/
```

- **scheme handler 只服务发起请求的那个应用的 `src/`（Builder 正在修改时）或 `current/`（其他时候）**，宿主数据永远不在这棵树里（[03](03-app-runtime.md) 第 5 节）。
- 应用私有数据：界面和核心的 `localStorage` 在 WebView 数据存储里；原生应用的数据在 `system/appdata/<id>/`，Seatbelt 规则只允许它读写这里。

**从 P0 迁移（P1a，首次启动新版本时自动执行）：**

1. `meta/`、`logs/`、`agent/` 移到 `system/` 下。
2. 每个 P0 应用：`apps/<id>/index.html` 及其他文件移到 `apps/<id>/src/ui/`；生成空的 `interface.json`、只有占位的 `core.js` 和清单；`git init` 并提交为 `1.0.0+1`；生成 `versions/1.0.0+1/` 和 `current`。
3. Agent SDK 的会话按工作目录存放，工作目录从 `apps/<id>/` 变成 `apps/<id>/src/` 后，旧会话无法续接。迁移后这些应用的下一次对话开启新会话，并把 `SPEC.md`（迁移时根据旧对话记录生成摘要）作为上下文。
4. 迁移失败时保留原目录，下次启动重试，并在设置里提示。

## 5. 产物类型与构建

| | A：JS 动态应用 | B：本地编译 | C：云端构建 | W：WASM 模块 | O：OCI 服务 |
|---|---|---|---|---|---|
| 阶段 | **P1a** | P4 | P4（按需） | P4 | P3 |
| 构建地点 | 不需要构建 | 用户的 Mac | 用户自己的 GitHub Actions | 本地或云端 | 本地（VM）或云端 |
| 构建耗时 | 0，重载约 5 ms | 热编译 0.4–0.7 s，首次 SwiftPM 构建约 30 s | 以分钟计 | 秒级 | 秒到分钟级 |
| 需要的工具链 | 无 | Command Line Tools（1.9 GB，已确认可以要求用户安装） | 无 | 内嵌 | 内嵌（Containerization） |
| 运行时 | 界面 WebView + 核心宿主 | 原生进程 | 原生进程 | WASM | VM |
| 费用 | 只有模型调用费 | 免费 | 约 $0.062/分钟（`macos-26` runner），每次约 $0.06–0.5，费用归用户 | 免费 | 本地免费 |
| 适合场景 | 默认 | Metal、120 Hz、系统集成、导出成独立 `.app` | 依赖重、非 Mac 目标平台、可复现的分享构建 | 计算模块 | 后端和服务 |

### 5.1 A 类：不需要构建

Builder 在 `src/` 里修改，界面和核心直接从 `src/` 加载以便实时热更新。一轮修改结束、测试通过后，宿主把 `src/` 的提交导出成 `versions/<ver>/` 快照，`current` 指向它（第 6 节）。

### 5.2 B 类：本地编译（P4）

1. 检查工具链：`xcode-select -p`。如果没有，引导用户执行 `xcode-select --install`。Apple 的 SDK 按许可不能随 AgentOS 分发。
2. 编译：单文件用 `swiftc`，多模块用 `swift build`。由宿主组装 `X.app/Contents/{MacOS, Info.plist, Resources}`，不需要 Xcode 工程。
3. 签名：链接器会自动做 ad-hoc 签名；宿主再根据能力授权生成 Seatbelt 规则，**包里自带的授权文件一律忽略**。
4. 编译错误作为工具结果返回给 Builder，进入修复闭环。
5. 也可以在 Workbench VM 里编译 Linux 目标（O 类后端、命令行工具）。

### 5.3 C 类：云端构建（用户自带 GitHub 账号，P4 按需）

```
Builder 打包源码和清单（以 sha256 标识）
 → 推送到用户自己的仓库（例如 <user>/agentos-builds），触发 workflow_dispatch
 → runner（macos-26 或 Linux）执行：构建 → ad-hoc 签名 → 跑测试 → 记录摘要 → 生成构建证明 → 上传产物
 → AgentOS 下载 → 校验摘要和构建证明 → 本地重新签名 → 按第 6 节安装
```

- 用户在设置里连接 GitHub（细粒度令牌，存在钥匙串里），AgentOS 帮用户创建构建仓库和工作流模板。
- 这个方案不碰 Apple 的签名和 Xcode 许可红线，费用和许可义务都归用户，和「自带 API Key」的思路一致。

## 6. 安装、升级、回滚、卸载

**安装和升级（所有类型通用，A 类在 P1a 实现）：**

1. **校验结构**：清单和 `interface.json` 符合 schema；接口 lint 通过（[05](05-app-protocol.md) 第 13 节）。
2. **计算副作用上限**：按申请的能力推导每个工具的上限（[05](05-app-protocol.md) 第 2.3 节）。
3. **接口兼容检查**（P1b）：和当前版本比较；破坏性变化列出受影响的依赖方，需要处理后才能继续（[05](05-app-protocol.md) 第 5 节）。
4. **权限对比**：新增或扩大的能力，按 [09](09-security.md) 第 5.2 节的规则授予（自动授予，或由外壳弹出授权框）。
5. **契约测试**：在临时的核心宿主和数据副本上运行，失败就终止。
6. **提交**：`src/` 做一次 git 提交，导出成 `versions/<ver>/`。
7. **切换**：原子切换 `current`；注册或更新接口；发出 `app.installed` 或 `app.updated` 事件。
8. **保留**：保留最近 10 个版本。
9. **数据迁移**：如果应用改了它的用户 schema（[08](08-data.md) 第 3 节），先备份受影响的集合，再执行迁移。

每个版本都记录测试结果。冒烟测试或契约测试没通过的版本仍然保留（用户可能想看），但在版本时间线里标红，不能成为 `current`。

**回滚：** 把 `current` 切回旧版本；`src/` 上追加一个「回到 x.y.z」的提交，这样 Builder 下次从回滚后的代码继续。**共享数据和 `localStorage` 都保留**；只有当这次升级做过用户 schema 迁移时，才询问是否连数据一起恢复。活动流里的「撤销这次修改」也走这条路（[00](00-kernel.md) 第 7 节）。

**卸载：** 注销接口和订阅、撤销能力授权 → 删除 `apps/<id>/`、`system/meta/<id>/` 和 WebView 数据存储。**共享集合里的数据不删**：它属于用户，不属于应用；没有任何应用使用的用户集合，会在设置的「数据」页里列出，可以导出或删除（[08](08-data.md) 第 3 节）。

## 7. 版本与 git

- 每个应用的 `src/` 是一个 git 仓库。**Builder 每完成一轮修改（测试通过）提交一次**，而不是每写一个文件就提交；提交说明用这轮对话的请求摘要。
- 版本号采用 `主.次.修订+构建号`：Builder 加功能时提升次版本号，修 bug 时提升修订号，接口有破坏性变化时提升主版本号；构建号单调递增。
- Builder 一轮修改结束时调用 `app.commit` 触发第 6 节的安装流程。「回到昨天的版本」「对比两个版本」由 Agent 通过 `app.versions`、`app.diff`、`app.rollback` 完成。

## 8. 包格式 `.agentpkg`（导出、导入、C 类）

一个版本目录本身就是解包后的 `.agentpkg`。打包成单个文件时：

```
<id>-<version>.agentpkg        # zip
├── manifest.json              # 带 artifacts、provenance、signature
├── src/                       # 源码，始终附带，任何版本都能重新构建、继续迭代
├── payload/                   # 运行用的产物：A 类就是 src 的副本，B/C 类是 X.app，W 类是 app.wasm
└── provenance/                # 构建来源、构建证明
```

- 签名：Ed25519，对规范化后的清单签名；私钥存在钥匙串里。
- 导入第三方的 `.agentpkg` 时：校验签名和摘要，**一律按新应用安装**，所有能力授权重新申请，不继承原作者的任何授权。
- A 类还可以导出成单个 HTML 文件（只含界面，供分享演示）。B/C 类导出成 `.app`；只有用户拥有自己的 Developer ID 时，才在本地签名并公证。

## 9. 信任与 Apple 政策红线

- **AgentOS 是信任关口。** AgentOS 自己下载的文件不带隔离标记（没有设置 `LSFileQuarantineEnabled`），不会经过 Gatekeeper 检查，所以第 6 节和第 8 节的校验必须严格执行。用户从网页或邮件里下载的文件，则必须保留隔离标记。
- **不能用 AgentOS 的开发者证书给用户的应用签名。** 开发者计划许可协议 §5.1 禁止这样做，而且一旦证书被吊销，AgentOS 本体也无法运行。
- **不自建托管的 Xcode 构建服务。** Xcode 许可只允许内部使用，禁止通过网络供多台机器同时使用。
- **SwiftPM 依赖**要锁定版本，并使用白名单，防范供应链风险。

## 10. 里程碑

| 阶段 | 内容 |
|---|---|
| P0 ✅ | 简化的注册表（只有清单，没有版本） |
| P1a | 应用结构；目录迁移；git；A 类的安装、升级、回滚、卸载；版本时间线和测试结果；包管理工具（`app.create`、`app.commit`、`app.versions`、`app.diff`、`app.rollback`） |
| P1b | 接口兼容检查；能力授权框接入安装流程 |
| P3 | O 类服务（VM 内） |
| P4 | B 类本地编译和原生安装；`.agentpkg` 导出导入与签名；C 类云端构建（按需）；W 类 |

## 11. 待定问题

- 应用的命名空间和 UUID 之外，要不要给用户一个可读的「应用短名」用于 `aos` CLI 和 `@` 提及？建议直接复用命名空间。
- Builder 修改到一半（测试没过）时用户切走，`src/` 里的未提交修改怎么办？建议保留在工作区，下次打开时由 Builder 决定继续还是丢弃。
