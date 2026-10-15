# AgentOS

**一台会生长的电脑。** Personal AgentOS 是 macOS 上的生成式个人操作系统。

- **它能做的事**：电脑在应用层能做的它都能做，比如开发和玩游戏、上网查资料、收发邮件、看电影、写文档和博客。
- **应用从哪来**：没有预装应用。所有应用都是你和 Agent 在使用过程中生成、迭代出来的。
- **应用之间的关系**：每个应用天生支持同一套协议，可以互相调用、订阅彼此的事件；你的 Agent 拥有照料它们的全部权限。

[![AgentOS 概念介绍页](docs/design/cover.png)](https://dyman1024.github.io/AgentOS/)

**[打开概念介绍页 →](https://dyman1024.github.io/AgentOS/)**

这是一份可以直接操作的交互设计稿，内容包括：

- 四个核心场景的原型：一句话生成应用、应用之间互联、自主行动与授权、撤销与回滚；
- 系统剖面图；
- 设计语言。

源文件在 [docs/design/](docs/design/README.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [概念介绍页（交互设计稿）](docs/design/README.md) | 产品概念、可交互原型、设计语言 |
| [技术方案](docs/architecture/README.md) | 总览加 00–11 共 12 份分册，开发以此为准 |
| [产品愿景](docs/vision/personal-agentos.md) | Personal AgentOS 的定位和设计原则 |
| [调研记录](docs/README.md) | 方案对比、实测数据和实验代码 |
| [AGENTS.md](AGENTS.md) | 给 AI Agent 和协作者的工作约定（全程中文、文档规则、常用命令） |

## 当前版本：从零重建

以正式技术方案和设计稿为基线，默认工程已切换到 `Host/`、`Sources/` 和新的引擎入口。原型 `App/` 保留供历史参考，不参与构建。

已实现内核与共享数据、应用核心与界面、包版本和回滚、应用互联、固定自动化、模型接入、系统服务、VM 与 OCI 后端、原生沙箱、恢复和发行工具。**本地确定性验证已通过，真实模型质量、桌面交互、真实账户和正式发行验收尚未完成。** 具体结果见 [重建方案](docs/architecture/12-rebuild-plan.md) 和 [验收记录](docs/verification/2026-10-16-rebuild.md)。

## 开发与运行

要求 Apple Silicon、macOS 26、Xcode 26.6、XcodeGen 和 Bun 1.3.14。本机实测环境为 macOS 26.5.1 / Swift 6.3.3。应用运行不依赖 Docker；开发构建 VM 镜像时才使用独立 Linux 构建器。

```bash
cd agent-engine
bun install --frozen-lockfile
cd ..
make run
```

| 命令 | 作用 |
|---|---|
| `make check` | 54 项 Swift 测试、WebKit 沙箱、原生编译与沙箱、OCI 解析、引擎类型检查、宿主构建 |
| `make background-test` | 独立测试数据上的前后台单一内核交接 |
| `make selftest` | 真实无窗口核心、协议、事件、自动化、WASM、解析与 UI Kit 集成 |
| `make sandbox-test` | 全套 WebKit 隔离探针和运行时集成 |
| `make build` / `make project` | 构建开发 App / 生成 Xcode 工程 |

首次启动是空启动台。在设置中填写自己的模型 Key，再通过 Builder 创建应用。凭据保存在钥匙串。设置中的外部服务只在配置后可用；付费评测默认不运行。

新数据根为 `~/Library/Application Support/AgentOS-Rebuild/`，与旧原型分开。用 `AGENTOS_DATA_ROOT` 指定测试目录；引擎源码调试入口为 `AGENTOS_ENGINE_CMD="bun run $PWD/agent-engine/src/rebuild.ts"`。原型的自动提示和 `--selftest-runtime` 开关不适用于新宿主。

更多操作见 [使用说明](docs/user-guide.md)、[VM 与镜像](vm/README.md)、[评测说明](evals/README.md)、[工程与发行](docs/architecture/11-engineering.md)。
