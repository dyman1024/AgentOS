# Native 编译方案实验

[../native-vs-web.md](../native-vs-web.md) 第 2 节的数据由这里的代码测得。

| 文件 | 内容 |
|---|---|
| `snake_appkit.swift` | AppKit 版贪吃蛇（`NSView` + `CADisplayLink`），导出 `agentos_make_view` |
| `snake_swiftui.swift` | SwiftUI 版（`@Observable` + `Canvas` + `TimelineView`） |
| `crash.swift` | 故意数组越界，用来验证生成代码崩溃会不会带垮宿主 |
| `host.swift` | 宿主：`dlopen` 加载、同名模块重复加载、`dlclose` 卸载、崩溃测试 |

```bash
xcrun swiftc -emit-library -module-name SnakeA1 -Onone snake_appkit.swift -o libA1.dylib
```

```bash
xcrun swiftc -Onone host.swift -o host
```

```bash
./host load "$PWD/libA1.dylib" "$PWD/libA1.dylib" "$PWD/libA1.dylib"
```
