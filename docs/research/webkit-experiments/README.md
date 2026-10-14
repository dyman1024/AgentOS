# WebKit 运行时实验（2026-10-15，macOS 26.5.1 / Xcode 26.6 / WebKit 26.5）

调研阶段用来验证 WKWebView 作为「生成应用运行时」的可行性，结论汇总在 [../architecture-research.md](../architecture-research.md) 第 3.3 节。

| 文件 | 验证内容 |
|---|---|
| `test.swift` | 自定义 scheme `agentos://` 的安全上下文、ES Module / import map / Blob import、WebGPU / WebGL2 / AudioContext、rAF 帧率、冷/热启动耗时、CSP 头拦截外网、`WKWebsiteDataStore(forIdentifier:)` |
| `test2.swift` | `sandbox="allow-scripts"` iframe 仍能调用 `webkit.messageHandlers`（桥接泄漏）、CSP 缺失时 CDN import / img / fetch / WebSocket 全部放行、`takeSnapshot` 能截到 WebGL 像素、AudioContext 无手势 resume |
| `test3.swift` | SwiftUI `WebPage`（macOS 26）+ `URLSchemeHandler` + `WKScriptMessageHandlerWithReply` + `WKContentRuleList` 拦截网络 |
| `test4.swift` | `securityRestrictionMode = .maximizeCompatibility`（macOS 26.5 新增）对 JS 性能的影响（约慢 5 倍） |
| `test5.swift` | `while(true){}` 死循环：WKWebView 释放后 WebContent 进程仍持续占满 CPU |
| `test6.swift` | `WebPage` 默认配置下的 JS 调用 |
| `jsc.swift` + `jit.plist` | `JSContext` 在有无 `com.apple.security.cs.allow-jit` 时的性能差异 |

单文件编译运行示例：

```bash
swiftc -O docs/research/webkit-experiments/test.swift -o /tmp/wktest && /tmp/wktest
```
