# Virtualization.framework 实验

[../system-architecture.md](../system-architecture.md) 第 2 节的数据由这里的代码测得。测试环境：M5 Pro，48 GB 内存，macOS 26.5.1。

| 文件 | 内容 |
|---|---|
| `boot.swift` | 极简 Linux VM：直接引导内核 + initramfs，测量从 `start()` 到用户态就绪的时间 |
| `snapshot.swift` | `saveMachineStateTo` / `restoreMachineStateFrom` 的耗时和状态文件大小 |
| `graphics-capabilities.swift` | 检查 virtio-gpu、virtiofs、vsock、Rosetta 等设备组合能否通过保存/恢复校验 |
| `virtualization.entitlements` | `com.apple.security.virtualization` 授权，编译后需用它签名 |

实验用的内核来自本机 Docker Desktop 自带的 linuxkit 内核，用户态取自本地 alpine 镜像里的 busybox，没有额外下载任何东西。

```bash
xcrun swiftc -O boot.swift -o vzboot && codesign -s - --entitlements virtualization.entitlements -f vzboot
```

```bash
./vzboot /Applications/Docker.app/Contents/Resources/linuxkit/kernel <rootfs.img> 512
```
