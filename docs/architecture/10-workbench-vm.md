# 10 工作间虚拟机（Workbench VM）

> 所属：[技术方案总览](README.md) ｜ 相关：[02 Agent](02-agent.md)、[04 应用包](04-app-package.md)、[07 服务](07-system-services.md)、[09 安全](09-security.md)
>
> 依据：[system-architecture.md](../research/system-architecture.md) 第 2 节、[vm-experiments/](../research/vm-experiments/)、[tech-assessment.md](../research/tech-assessment.md) 第 3.9 节和第 6 节

## 1. 定位

**体验像 Parallels，实现像 WSL2。** 用户看到的是一个独立完整的 AgentOS 系统；系统内部有一台**用户看不见的 Linux 微虚拟机**，作为 Agent 的「工作间」，负责：

- **工具链**：apt、pip、npm、gcc、Rust、Go、ffmpeg、Python 等，Agent 拿到 root 权限，用户不用在 Mac 上安装任何东西。
- **应用后端和服务**：数据处理、爬虫、定时任务、数据库（O 类产物）。
- **不可信代码**：一次性脚本、网上下载的程序，放在临时微虚拟机里运行，用完即弃。
- **构建**：Linux 目标的编译；云端构建前的本地预检。
- **代码模式**：Agent 写一段脚本批量调用应用工具（[05](05-app-protocol.md) 第 9 节）。

**不把用户应用放进 VM**，原因有三：

1. Linux 来宾在 Apple 的虚拟化框架下没有 3D 加速。
2. 要让来宾应用逐个窗口地融入 Mac 桌面，等于自己再造一个 WSLg，工作量以月计；中文输入法、剪贴板这些也都要额外桥接。
3. 来宾占用的内存不会还给宿主。

所以应用界面一律在宿主上渲染。「体验像 Parallels」来自外壳（全屏桌面模式、独立的数据和回滚），不来自 VM。

**为什么放到 P3：** P2 的研究助手只需要搜索和网页正文提取，后者用隐藏的 WKWebView 就能完成（网页脚本本来就跑在 Apple 沙箱化的 WebContent 进程里，[07](07-system-services.md) 第 3.2 节）。VM 真正不可替代的是工具链、应用后端和不可信代码，它们从 P3 开始需要。

## 2. 实测数据（M5 Pro，48 GB，macOS 26.5）

| 项 | 结果 |
|---|---|
| 极简 Linux VM 启动（2 vCPU） | `start()` 72–87 ms；用户态就绪 230–300 ms |
| 空闲时占用宿主内存 | 配置 512 MB 时 115 MB；配置 4 GB 时 254 MB |
| 保存和恢复整机状态 | 512 MB：235 ms 和 172 ms；4 GB：675 ms 和 618 ms；状态文件 22–46 MB |
| 保存和恢复的兼容性 | 同时配置 virtio-gpu、virtiofs、NAT、vsock、Rosetta 共享时，仍能通过校验 |
| 内存归还 | **不归还**：Docker 的 VM 实际用了约 3.5 GB，宿主侧却被占住 24 GB |
| 容器启动参照 | `docker run --rm alpine true` 中位数 211 ms；`docker exec` 42 ms |

## 3. 实现

| 项 | 设计 |
|---|---|
| 技术栈 | **Apple Containerization**（Swift 包，Apache-2.0），直接跑在 AgentOS 进程里，不依赖 Docker、OrbStack 或 Parallels；底层是 Virtualization.framework。要求 Apple 芯片和 macOS 26。**截至 2026-10 仍是 0.x 版本（0.51.0）**，API 可能变动 |
| 授权 | 只需要 `com.apple.security.virtualization`（不受限，Developer ID 可用）；需要随应用分发 Linux 内核和 `vminitd` |
| 实例 | 一台**常驻 Workbench VM**（arm64 Linux，内存上限 4–8 GB，持久磁盘存放工具链和缓存），加上按需创建的**临时微虚拟机**（运行不可信代码，用完即弃） |
| 镜像 | 基础镜像为 arm64 OCI，预装常用工具链；首次启动时下载（几百 MB 到几 GB，需要提示用户），之后增量更新 |
| 控制通道 | vsock 上的 gRPC（Containerization 的 vminitd）；面向 Agent 和服务的 MCP 也走 vsock |
| 文件 | virtiofs **只共享授权目录**：Agent 的工作区、应用的后端目录、用户明确授权的文件夹 |
| 网络 | **不配直通网卡。** VM 的网络接口接到宿主侧的用户态网络栈（vfkit 加 gvproxy 那一类做法，经文件句柄或 vsock 转发），由宿主按域名白名单放行并记入审计。Containerization 默认不配网卡，允许接入自定义的网络附件，所以可行（已核实源码） |
| 快照 | 用 `saveMachineState` 实现秒级挂起和恢复；磁盘回滚用 APFS 克隆 |
| 资源 | 设内存上限；空闲时挂起；定期重启以收回内存；临时 VM 有时长和资源上限 |

**为什么不用 NAT 加代理：** 只要 VM 有一块能直通 NAT 的网卡，代理设置就只是建议，被注入的代码可以绕开。出站控制必须是强制的，所以网卡本身就不能直通外网。

## 4. 对外接口（工具）

| 工具 | 说明 | 使用者 |
|---|---|---|
| `vm.exec({cmd, cwd?, env?, timeout?, ephemeral?})` | 执行命令，返回 stdout、stderr 和退出码；设置 `ephemeral` 时在临时微虚拟机里执行 | Agent、包管理 |
| `vm.fs.read` / `write` / `list` | 读写 VM 工作区里的文件 | Agent |
| `vm.service.start` / `stop` / `status` | 管理常驻服务（应用后端） | Agent、应用（通过 `call` 授权） |
| `vm.snapshot` / `restore` | 给工作间打快照、回滚 | Agent、恢复模式 |
| `vm.stats` | 内存、CPU、磁盘占用 | 外壳 |

- VM 里的服务以 MCP Server 的形式经 vsock 接入宿主，和其他应用平等地参与协议和总线（[05](05-app-protocol.md)、[06](06-event-bus.md)）。
- VM 里的命令行可以调用 `aos`，经 vsock 转发到宿主，主体是 `vm:<id>`，权限按发起它的运行计算（[00](00-kernel.md) 第 3.4 节）。
- `vm.exec` 的输出如果来自网络（例如下载的网页），宿主无法区分；所以执行过联网命令的 VM 会话，结果一律标为不可信。

## 5. 图形界面（补充方案）

- 默认没有图形界面。
- Agent 需要「看」Linux 图形应用时（computer use），用 Xvfb 加 noVNC 在一个 WebView 面板里显示，或者给它开一个整屏的 `VZVirtualMachineView` 窗口。
- 逐窗口融入 Mac 桌面的方案（类似 WSLg）暂不做。

## 6. macOS 来宾 VM（可选，P4）

- 唯一的用途是让 Agent **安全地操作真实的 Mac 应用**（computer use）。
- 限制：每台 Mac 最多同时运行 2 个；许可只允许开发、测试或个人非商业用途；App Store 登录不可用；每个来宾需要 4–8 GB 内存。启用前需要做许可评估。

## 7. 里程碑

| 阶段 | 内容 |
|---|---|
| P3 | 常驻 Workbench VM、镜像下载和更新、vsock 控制通道、用户态网络栈和出站白名单、virtiofs 授权目录、`vm.exec` 和 `vm.fs`、快照；临时微虚拟机；VM 服务作为应用后端接入总线；代码模式 |
| P4 | Xvfb 加 noVNC 图形面板；可选的 macOS 来宾 VM |

P3 之前先做 S7（[11](11-engineering.md) 第 8 节）：验证不配直通网卡时，VM 里的进程无法绕过白名单。

## 8. 风险

- Containerization 仍是 0.x，API 可能变动。必要时可以退回直接用 Virtualization.framework（实测代码见 [vm-experiments/](../research/vm-experiments/)）。
- macOS 26 新的 vmnet 网络接口：Apple 自己的 `container` 只用了虚拟化授权，但 vmnet 的官方文档仍写着沙箱进程需要受限的 `com.apple.vm.networking`。本方案不依赖 vmnet，避开这个不确定性。
- 内存不归还，需要设上限并定期回收。
- Linux 的 Rosetta 在 macOS 27 之后是否继续提供尚不确定，所以统一使用 arm64 镜像。
- 首次下载体积较大，需要在引导流程里说明并显示进度。
- 被注入的代码可能借 VM 外泄数据，必须靠用户态网络栈的白名单和严格限定共享目录来守住。
