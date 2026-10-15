# 运行时沙箱探针

[../tech-assessment.md](../tech-assessment.md) 第 2 节的结论由这里的页面测得。测试环境：M5 Pro，macOS 26.5，P0 构建（`feat: P0 prototype of AgentOS`）。

现有的 [tests/fixtures/sandbox-escape.html](../../../tests/fixtures/sandbox-escape.html) 只覆盖 `<img>`、`fetch`、远程 `import` 和 WebSocket 四种外网访问。这三个探针补测的是「应用之间、应用与宿主数据之间」的隔离，以及 CSP 管不到的出网通道。探针只记录状态码、长度和布尔值，不读取文件内容。

| 文件 | 测什么 | 结果 |
|---|---|---|
| `probe1-egress-and-isolation.html` | 跨应用 `fetch`；以 `..` 作为 host 的越界路径；WebRTC；同源 iframe 是否带 shim；测试钩子能否被改写 | 跨应用和越界的 `fetch` 被 CORS 拦下；但 `<script src="agentos://../apps/<id>/index.html">` 触发 `load`，不存在的文件触发 `error`，**说明越界路径能被宿主正常响应**；`RTCPeerConnection` 可用；srcdoc iframe 同源且没有 shim；`window.__agentos` 可写 |
| `probe2-iframe-traversal.html` | 用 iframe 加载 `agentos://..` 下的页面，在 iframe 里同源读取 | iframe 被 CSP `frame-src` 拦截（`default-src 'none'` 生效）；ICE 收集正常进行，2 秒内只拿到 host 候选 |
| `probe3-toplevel-traversal.html` | 顶层导航到 `agentos://..`，同源读取数据根目录下的文件，再带着结果导航回本应用 | **成功**：读到了 `apps/<id>/index.html`、`meta/<id>/manifest.json`、`logs/selftest-result.json`（均为 200），结果经 URL 片段带回本应用的 origin |

运行方式（任意一个探针）：

```bash
build/Build/Products/Debug/AgentOS.app/Contents/MacOS/AgentOS --selftest-runtime docs/research/sandbox-probes/probe3-toplevel-traversal.html
```

结果在 `~/Library/Application Support/AgentOS/logs/selftest-result.json` 的 `smoke_test.state_after` 里。
