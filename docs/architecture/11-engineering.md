# 11 工程体系

> 所属：[技术方案总览](README.md)。重建工程的当前入口，旧 P0 命令不再适用。完整阶段状态见 [12](12-rebuild-plan.md)。

## 1. 模块与构建

| 路径 | 责任 |
|---|---|
| `Host/` | SwiftUI/AppKit 外壳、模型、账户、个人服务、后台交接和恢复 |
| `Sources/AgentOSCore/` | SQLite 内核、数据、授权、标签、事件、版本、自动化和确定性服务 |
| `Sources/AgentOSRuntime/` | WebKit 核心/UI、SDK、原生编译与沙箱、正文解析、VM/后端 |
| `Sources/RuntimeChecks/`、`NativeChecks/`、`VMChecks/` | 实际框架与隔离集成测试 |
| `Sources/aos/` | 随 App 打包的 CLI，通过认证 Unix socket 使用宿主 |
| `agent-engine/src/rebuild.ts` | Claude Agent SDK / Bun sidecar，仅提供宿主工具 |
| `ui-kit/` | 锁版本浏览器库构建；包括界面组件、编辑器、图表、MIME 解析 |
| `vm/` | arm64 Linux 开发镜像、vsock 来宾代理和 OCI 处理 |
| `evals/` | 真实模型 S4/S6 评测；S3 入口在 agent-engine |
| `App/`、旧引擎 index.ts | 原型背景，不参与默认构建 |

要求 Apple Silicon、macOS 26、Xcode 26.6、Swift 6、Bun 1.3.14、XcodeGen。本机实测 macOS 26.5.1 / Swift 6.3.3。`project.yml` 将部署目标固定为 macOS 26.0、架构固定为 arm64，与用户确认的平台要求一致。

依赖锁定：Bun lockfile、Sparkle 2.10.0 精确版本。SQLite、WebKit、Virtualization、NaturalLanguage、EventKit 与 Contacts 使用系统框架。UI 库由 `make ui-kit` 生成并复制到 Bundle，不提交生成文件。

```bash
cd agent-engine
bun install --frozen-lockfile
cd ..
make run
```

## 2. 验证入口

| 命令 | 验证范围 | 是否付费/需要账户 |
|---|---|---|
| `make core-test` | 55 项 Swift Testing：事务、撤销、权限、预算、事件、迁移、包、HTTP、文件、邮件、MCP | 否 |
| `make selftest` | 真实 WebKit 核心、协议、事件、自动化、WASM、解析、UI Kit | 否 |
| `make sandbox-test` | 上述集成及所有 `sandbox-*.html` 探针 | 否 |
| `make native-test` | swiftc、Seatbelt、共享数据调用、进程退出与恢复 | 否；需要 CLT |
| `make guest-test` | OCI 布局/摘要/架构/目录边界与来宾语法 | 否 |
| `make engine-check` | TypeScript 类型检查 | 否 |
| `make build` | UI Kit、XcodeGen、Debug 宿主、引擎与 CLI 打包 | 否 |
| `make check` | core-test、sandbox-test、native-test、guest-test、engine-check、build | 否 |
| `make release-test` | hardened Release、引擎/Claude 启动；有 Apple Team ID 才运行 Release 宿主交接 | 否；不调用模型 |
| `make background-test` | 真实独立前后台进程的排他租约交接与持久化 | 否；不注册登录项 |
| [VMChecks](../../vm/README.md) | 真实 VM、出站、Node/OCI 后端、冷恢复 | 无模型费；需要镜像和授权 HTTPS 网络 |

测试使用独立临时根目录。WebKit 核心采用无窗口宿主和 `inactiveSchedulingPolicy = .none`。自动测试不等于真实窗口视觉与点击验收。UI 沙箱探针仍需完整通过，不得只跑内核测试代替。

## 3. 配置与诊断

| 配置 | 含义 |
|---|---|
| `AGENTOS_DATA_ROOT` | 隔离根目录；默认 `~/Library/Application Support/AgentOS-Rebuild/` |
| `AGENTOS_ENGINE_CMD="bun run $PWD/agent-engine/src/rebuild.ts"` | 引擎源码调试入口 |
| `AGENTOS_SAFE_MODE=1` | 进入恢复模式，停用生成桌面与自动化 |
| `AGENTOS_EVAL=1` | 仅在显式隔离的 `agentos-eval-*` 数据根允许评测 RPC |
| `ANTHROPIC_API_KEY` / `OPENROUTER_API_KEY` | 钥匙串中无凭据时的开发环境回退 |
| `BRAVE_SEARCH_API_KEY` / `AGENTOS_GITHUB_TOKEN` | 系统服务凭据回退；生成应用不可读取 |

诊断先看宿主活动详情和通知，再看 `system/kernel.sqlite` 中运行、副作用、事件与审计；Agent SDK 配置和会话位于 `system/agent/`，映射位于 `system/agent-sessions.json`。会话和调试日志可能含私人内容，不应直接贴到公共 issue。

引擎 stdio 有帧/队列上限和请求超时；主运行 30 分钟截止，取消超过 10 秒结束 sidecar。预算预留在未知结果时保守结算，实际用量到达后可核对一次。外部写入的 unknown 状态不自动重发。

## 4. 技术验证与质量门槛

| 编号 | 方法 | 通过标准 | 当前结果 |
|---|---|---|---|
| S1 | 无窗口核心持续调用，分别测宿主和 WebContent 内存 | 连续 1 小时、p95<200 ms、内存有数据 | 通过：3600 秒/721 次/零失败，p95 13.316 ms；[结果](../verification/2026-10-16-core-host-memory.json) |
| S2 | scheme、CSP、导航、iframe、消息桥和 WebRTC 探针 | 所有越界访问被阻断；自身核心与数据操作正常 | 本地通过 |
| S3 | 50/100/200 工具 × 元工具/SDK Tool Search × 10 任务 | 两策略实际可比较，准确率/费用/时延有完整记录 | 入口及 dry run 已验证；未调用真实模型 |
| S4 | 笔记、待办、书签、记账各 10 次生成 | 首次提交成功率≥80%；独立任务接口覆盖≥90% | 入口及 dry run 已验证；未实跑 |
| S5 | hardened runtime、Developer ID、公证、Sparkle、干净 Mac | 安装、Gatekeeper、升级、模型调用通过，SDK 再分发条件确认 | ad-hoc Release 构建/签名本地通过；正式发行未通过 |
| S6 | 20 个研究整理任务，固定素材、真实模型与真实出口策略 | 全部保存文档与引用，平均确认<1，没有越权出口 | 入口及 dry run 已验证；未实跑 |
| S7 | 真 VM 无网卡、伪造令牌/未授权域名、允许的宿主出口 | 无法绕过出口策略；允许的请求实际成功 | 本地通过；包含 Node/OCI 隔离后端 |

S4 的独立任务测试直接调用生成应用的 IDL，核对新增/修改/删除/检索/分类/排序/去重/汇总；应用自己编写的契约通过不会自动计作覆盖率 100%。S6 使用本地素材消除搜索结果漂移，不能代替真实网页质量与真实账户验收。运行方式见 [评测说明](../../evals/README.md)。

## 5. 持续集成

`.github/workflows/rebuild.yml` 使用 macOS 26 / Xcode 26.6、固定 SHA 的 checkout/setup-bun、冻结 Bun 依赖；运行 `make check`、前后台交接及所有免费评测预检。没有模型 Key，不进行付费请求。代码提交 057fcab 的远端 CI 已通过，见 [验收记录](../verification/2026-10-16-rebuild.md)；后续提交以 PR 的检查为准。工具链参考 [官方 runner 清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)。

## 6. 发行

Debug 使用 ad-hoc；Release 打开 hardened runtime，并对 Bun 引擎、Claude sidecar 和 aos 分别签名。默认不配置在线更新。Sparkle 只有在 HTTPS feed 与 32 字节 Ed25519 公钥齐备时启用，参见 [Sparkle 官方说明](https://sparkle-project.org/documentation/)。

`scripts/release.py --help` 列出所需身份与参数。脚本依次 archive/export、严格签名验证、notarytool、stapler、spctl、打 ZIP；不发布上传。生成签名 appcast、更新服务托管、SDK 再分发条款核实和干净 Mac 安装/升级/真实模型调用仍是发行前置条件。

工作间镜像与 App 分开签名：`scripts/sign-workbench-image.swift` 对镜像清单签名；客户端下载时验证独立配置的公钥、SHA-256 和长度。开发用 LinuxKit 内核不被视为已确定的公开发行内核。

## 7. 协作与完成定义

遵循 [AGENTS.md](../../AGENTS.md)：中文沟通、`feat/*` 分支、conventional commit 英文标题、中文 PR 描述；修改设计同步分册和总览决策。调研记录不可修改。公开提交不包含 Key、本机用户路径、测试数据和镜像。

完成阶段需要对应的证据。未配置、未实跑、平台失败分别记录，不能计作通过。当前交付及未通过项见 [重建方案](12-rebuild-plan.md) 与 [验收记录](../verification/2026-10-16-rebuild.md)。

Release 本机启动限制：Apple 的 library validation 不接受没有 Team ID 的 ad-hoc 宿主加载 Sparkle。即使双方都严格验签通过也不能满足这一运行条件，见 [Sparkle 官方说明](https://sparkle-project.org/documentation/)。保留 Release 的 library validation；无证书时 CI 只验证构建、签名和独立 sidecar 启动，将 Release 宿主启动明确标为 NOT RUN。开发宿主使用 Debug。

托管 CI 缺少 Apple 中文句向量资源时，真实中文语义集成测试显示 skipped；不会伪装通过或改成外部模型。另一个确定性测试验证缺少语言资源时返回 unavailable。本机中文模型存在，已实际运行相关性/版本/本地性测试。CI 的通过结论必须带上这一平台资源限制。
