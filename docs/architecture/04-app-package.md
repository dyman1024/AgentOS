# 04 应用包、构建与生命周期

> 所属：[技术方案总览](README.md) ｜ 相关：[03 运行时](03-app-runtime.md)、[05 协议](05-app-protocol.md)、[09 安全](09-security.md)、[10 工作间 VM](10-workbench-vm.md)
>
> 依据：[system-architecture.md](../research/system-architecture.md) 第 3 节

## 1. 职责

定义统一的应用包格式，并管理应用从诞生到卸载的全过程：创建、构建、校验、安装、升级、回滚、卸载、导出。三类产物共用同一套包格式和安装流程。

## 2. 产物类型

| | A：JS 动态应用 | B：本地编译 | C：云端构建 | W：WASM 模块 | O：OCI 服务 |
|---|---|---|---|---|---|
| 构建地点 | 不需要构建 | 用户的 Mac | 用户自己的 GitHub Actions | 本地或云端 | 本地（VM）或云端 |
| 构建耗时 | 0，重载约 5 ms | 热编译 0.4–0.7 s，首次 SwiftPM 构建约 30 s | 以分钟计 | 秒级 | 秒到分钟级 |
| 需要的工具链 | 无 | Command Line Tools（1.9 GB，已确认可以要求用户安装） | 无 | 内嵌 | 内嵌（Containerization） |
| 运行时 | Web | 原生进程 | 原生进程 | WASM | VM |
| 费用 | 只有模型调用费 | 免费 | 约 $0.062/分钟（`macos-26` runner），每次约 $0.06–0.5，费用归用户 | 免费 | 本地免费 |
| 适合场景 | 默认 | Metal、120 Hz、系统集成、导出成独立 `.app` | 依赖重、非 Mac 目标平台、可复现的分享构建 | 计算模块 | 后端和服务 |

## 3. 包格式 `.agentpkg`

```
<id>-<version>.agentpkg/
├── manifest.json        # 见下
├── payload/             # 运行用的产物：index.html… / X.app / app.wasm / OCI 引用
├── src/                 # 源码，始终附带，任何版本都能重新构建、继续迭代
├── interface/           # tools.json（工具快照）、schemas/（事件和数据 schema），见 05
├── tests/               # 冒烟测试和契约测试
├── SKILL.md             # 给 Agent 看的使用说明（见 05）
├── SPEC.md              # 应用规格说明（见 02）
└── provenance/          # 构建来源、构建证明（attestation）
```

```jsonc
{
  "schema": "agentos.app/1",
  "id": "app.agentos.u7f3.mail",          // 稳定不变；原生应用也用它做 bundle id
  "version": "1.4.0+27",                  // 语义化版本 + 递增的构建号
  "title": "邮件", "icon": "✉️",
  "runtime": { "kind": "web | macos-native | wasm-component | oci",
               "entry": "index.html | Mail.app | app.wasm | oci@sha256:…",
               "arch": ["arm64"], "minHost": "15.0" },
  "permissions": {                        // 见 09
    "network": ["imap.example.com"], "data": { "notes": "rw", "mail": "r" },
    "services": ["mail.send", "ai.complete"], "files": ["~/Documents/Blog"] },
  "interface": { /* 见 05：tools / emits / subscribes / calls / headless / skill / cli / ui */ },
  "source":    { "digest": "sha256:…", "recipe": "none | swiftc | swiftpm | cargo-component | containerfile" },
  "artifacts": [{ "path": "payload/Mail.app", "digest": "sha256:…", "size": 96288 }],
  "provenance":{ "builder": "local | gha:<user>/<repo>/.github/workflows/agentos-build.yml@<sha>",
                 "attestation": "provenance/build.sigstore.json" },
  "signature": { "alg": "ed25519", "keyId": "device:…", "sig": "…" },   // 对规范化后的清单签名
  "update":    { "previous": "1.3.2+26", "dataSchema": 3 },
  "agent":     { "sessionId": "…", "model": "claude-opus-5-5" }
}
```

## 4. 磁盘布局

```
~/Library/Application Support/AgentOS/
├── apps/<id>/
│   ├── src/              # 源码工作区（git 仓库，Builder 在这里改代码）
│   ├── versions/<ver>/   # 已安装的各个版本（不可变）
│   ├── current -> versions/<ver>
│   └── data/             # 应用私有数据（Seatbelt 规则只允许原生应用读写这里）
├── meta/<id>/            # 对话记录等宿主侧元数据
└── keys/                 # 本机签名密钥的引用（私钥存在钥匙串里）
```

**P0 现状：** 应用文件直接平铺在 `apps/<id>/`，`meta/<id>/manifest.json` 只有 `{id, title, icon, createdAt, updatedAt, sessionId}`，还没有版本管理（`App/Apps/AppRegistry.swift`）。P1 要迁移到上面的布局：把现有文件移到 `src/`，生成第一个版本，初始化 git。

## 5. 构建

### 5.1 A 类：不需要构建

把 `src/` 打包成 `versions/<ver>/` 的快照即可。JS 应用在开发过程中直接从 `src/` 加载，以便实时热更新；版本化之后，「当前版本」才指向快照。

### 5.2 B 类：本地编译

1. 检查工具链：`xcode-select -p`。如果没有，引导用户执行 `xcode-select --install`。Apple 的 SDK 按许可不能随 AgentOS 分发。
2. 编译：单文件用 `swiftc`，多模块用 `swift build`。由宿主组装 `X.app/Contents/{MacOS, Info.plist, Resources}`，不需要 Xcode 工程。
3. 签名：链接器会自动做 ad-hoc 签名；宿主再根据 `permissions` 生成 Seatbelt 规则，**包里自带的授权文件一律忽略**。
4. 编译错误作为工具结果返回给 Builder，进入修复闭环。
5. 也可以在 Workbench VM 里编译 Linux 目标（O 类后端、命令行工具）。

### 5.3 C 类：云端构建（用户自带 GitHub 账号）

```
Builder 打包源码和清单（以 sha256 标识）
 → 推送到用户自己的仓库（例如 <user>/agentos-builds），触发 workflow_dispatch
 → runner（macos-26 或 Linux）执行：构建 → ad-hoc 签名 → 跑测试 → 记录摘要 → 生成构建证明 → 上传产物
 → AgentOS 下载 → 校验（第 6 节）→ 本地重新签名 → 安装
```

- 用户在设置里连接 GitHub（用 OAuth 或细粒度令牌，存在钥匙串里），AgentOS 会帮用户创建构建仓库和工作流模板。
- 这个方案不碰 Apple 的签名和 Xcode 许可红线，费用和许可义务都归用户，和「自带 API Key」的思路一致。

## 6. 安装、升级、回滚、卸载

**安装和升级（所有类型通用）：**
1. 校验 `signature`（本机构建用设备密钥签名；云端构建再加上构建证明）。
2. 逐一校验 `artifacts` 的摘要。
3. C 类还要核对构建证明里的构建者身份，并确认 `source.digest` 和 Agent 提交的一致。
4. **权限对比**：新增或扩大的权限交给外壳弹出授权框（[01](01-shell.md)）。
5. 安装到 `versions/<ver>/`，原生应用在本地重新签名并生成 Seatbelt 规则。
6. 注册或更新接口（[05](05-app-protocol.md)），工具快照的哈希变了就要重新授权。
7. 跑冒烟测试和契约测试，失败就终止安装。
8. 原子切换 `current`，保留最近 N 个版本（默认 10 个）。
9. `dataSchema` 有变化时先备份数据，再执行迁移。

**回滚：** 把 `current` 切回旧版本；如果数据 schema 变过，就恢复对应的备份。活动流里的「撤销」也走这条路。

**卸载：** 注销接口和订阅 → 删除 `apps/<id>/`、`meta/<id>/` 和 WebView 数据。由于用 Seatbelt 和 AgentOS 自己的数据目录，而不用 App Sandbox 的容器目录，删除不会受阻；实测 App Sandbox 的容器目录宿主删不掉。

**导出与分享：**
- A 类可以导出成单个 HTML 文件，或 `.agentpkg`。
- B/C 类导出成 `.app`。只有用户拥有自己的 Developer ID 时，才在本地签名并公证。

## 7. 信任与 Apple 政策红线

- **AgentOS 是信任关口。** AgentOS 自己下载的文件不带隔离标记（没有设置 `LSFileQuarantineEnabled`），不会经过 Gatekeeper 检查，所以第 6 节的校验必须严格执行。用户从网页或邮件里下载的文件，则必须保留隔离标记。
- **不能用 AgentOS 的开发者证书给用户的应用签名。** 开发者计划许可协议 §5.1 禁止这样做，而且一旦证书被吊销，AgentOS 本体也无法运行。
- **不自建托管的 Xcode 构建服务。** Xcode 许可只允许内部使用，禁止通过网络供多台机器同时使用。
- **SwiftPM 依赖**要锁定版本，并使用白名单，防范供应链风险。

## 8. 版本与 git

- 每个应用的 `src/` 是一个 git 仓库，Builder 的每次修改都对应一个提交，提交说明用对话里的请求摘要。
- 版本号采用 `主.次.修订+构建号`：Builder 改功能时提升次版本号，修 bug 时提升修订号；构建号单调递增。
- 「回到昨天的版本」「对比两个版本」由 Agent 通过包管理工具完成。

## 9. 里程碑

| 阶段 | 内容 |
|---|---|
| P0 ✅ | 简化的注册表（只有清单，没有版本） |
| P1 | `.agentpkg` 格式、目录迁移、git、版本与回滚、安装流程（A 类）、设备签名密钥 |
| P3 | B 类本地编译和原生安装（Seatbelt 规则生成、重新签名） |
| P4 | C 类云端构建（GitHub 连接、工作流模板、构建证明校验）；W 类；导出分享 |
