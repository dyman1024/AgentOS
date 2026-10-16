# 工作间与应用后端

运行使用 Virtualization.framework，不依赖 Docker。Apple Silicon / macOS 26；默认 2 vCPU、1 GiB、无网卡、无宿主共享目录。来宾控制走 vsock 5201，显式宿主请求走 5202，令牌随一条命令失效。

## 开发镜像与测试

在独立 Alpine arm64 构建器中运行 `build-image.sh`，输入只读挂载本目录，输出到 `.workbench-cache/`。构建会安装工具链和 umoci/runc，输出 2 GiB 稀疏 ext4、摘要和包版本清单。镜像内可执行文件不会放进 Git。

```bash
mkdir -p .workbench-cache
docker run --rm --platform linux/arm64 \
  -v "$PWD/vm:/input:ro" -v "$PWD/.workbench-cache:/output" \
  alpine@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b \
  sh /input/build-image.sh
```

kernel 需另行提供适用于当前 virtio 配置的 arm64 Linux Image。本机验证使用已有 LinuxKit 开发内核；没有把它列为确定的公开再分发方案。基础 Alpine digest 已固定，apk 仓库的包版本会变化，发行时需固定完整构建输入并保存 packages.txt/SBOM。

生成最小 OCI 测试夹具（在 Linux 构建器中）：

```bash
docker run --rm --platform linux/arm64 \
  -v "$PWD/tests/fixtures:/input:ro" -v "$PWD/.workbench-cache:/output" \
  alpine@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b \
  sh -c 'apk add --no-cache python3 >/dev/null && python3 /input/build-oci-backend.py'
make ui-kit
swift build --product VMChecks
codesign --force --sign - --entitlements Config/Virtualization.entitlements .build/debug/VMChecks
VM_COLD_RESTORE=1 VM_OCI_ARCHIVE="$PWD/.workbench-cache/backend.oci.tar" \
  .build/debug/VMChecks "$AGENTOS_TEST_KERNEL" .workbench-cache/workbench.ext4
```

`AGENTOS_TEST_KERNEL` 指向开发者选择的内核。测试需要公网 example.com，仅验证经宿主许可的 HTTPS。`VM_SKIP_NETWORK=1` 可跳过真实出站，但该运行不能计作完整 S7 通过。每次 Swift 重编译后需重新签名 VMChecks。

测试覆盖直接 socket 拒绝、伪造令牌、域名授权、Node/OCI 契约隔离、持久进程、撤权、临时磁盘清理与冷磁盘恢复。去掉 `VM_COLD_RESTORE=1` 会验证完整内存恢复：将堆计数器从 41 改为 99，再恢复到 41，随后继续运行到 42；随机值、PID 与 boot ID 必须一致，并在新的宿主进程中重验。同轮还验证损坏状态文件不会丢失当前磁盘的最近写入，也不会自动冷启动。

本机 macOS 26.5.1 / M5 Pro 解锁时完整恢复通过；锁屏时 ad-hoc 与 Apple Development 均返回 `VZErrorDomain Code 12`，系统日志定位至 Secure Enclave 解密 `-25308`。开发者证书不是这项能力的必要条件。请在原 Mac、原用户下解锁后重试；不要修改锁屏、钥匙串或系统安全设置来绕过限制。详见[诊断证据](../docs/verification/2026-10-16-vm-memory.md)。

独立最小复现（只验证框架保存/恢复，不代替上述堆状态验收）：

```bash
swiftc scripts/vm-snapshot-check.swift -o .workbench-cache/vm-snapshot-check
codesign --force --sign - --entitlements Config/Virtualization.entitlements .workbench-cache/vm-snapshot-check
.workbench-cache/vm-snapshot-check "$AGENTOS_TEST_KERNEL" .workbench-cache/workbench.ext4
# 可加 --same-instance，或 --vsock；输出标明失败发生在哪个阶段。
```

在已确认锁屏的测试会话中可设置 `VM_EXPECT_LOCKED_RESTORE_FAILURE=1`，它严格要求出现 permission denied，并验证原磁盘最近写入被保留；如果恢复成功，该负向用例反而失败。不要把此模式作为日常内存验收或 CI 的跳过开关。

内存恢复后的工作间不自动闲置暂停，以保留新宿主尚未登记的常驻进程；显式停止或冷启动后恢复原闲置策略。快照仅在全部文件保存完成后可见。恢复失败返回 `vm_restore_failed`，包含底层错误域/码和磁盘回退状态；磁盘回退自身失败返回 `vm_restore_rollback_failed` 并保留备份文件。

## Node/Python 后端

```json
{
  "runtime": {
    "kind": "web", "core": "core.js", "ui": "ui/index.html",
    "backend": {"language":"node","entry":"backend/server.cjs","files":["backend/server.cjs"]}
  },
  "permissions": {"services":["backend.call"],"network":[],"files":[]}
}
```

核心调用 `agentos.backend.call("method", args)`。后端 stdin 每行接收 `{id,method,args}`，stdout 每行回复 `{id,result}` 或 `{id,error}`；日志写 stderr。Node/Python 最多 100 个 UTF-8 文件、每个 1 MB、合计 2 MB。请求/回复最多约 1 MB、20 秒截止；超时或不匹配回复终止进程，不重试原请求。

每个应用有独立持久磁盘，没有宿主 bridge token。最多两个驻留后端，空闲回收；契约测试另建临时 VM。所有后端输出保守标记为私人和外部来源。

## OCI 后端

将 language 改为 `oci`，entry/files 指向单个不超过 200 MB 的 `backend.oci.tar`。包必须是 [OCI image-layout](https://github.com/opencontainers/image-spec/blob/main/image-layout.md) tar：linux/arm64，单平台 manifest 的 `app` 标签，SHA-256，普通或 gzip 层。外层不允许链接或目录穿越。不是 Docker save 旧格式，不在运行时从仓库拉镜像。

镜像在独立来宾内由 [umoci](https://github.com/opencontainers/umoci) 解包、runc 执行，不在 macOS 上解压任何层。Entrypoint/Cmd 使用镜像配置，禁用 terminal；相同 NDJSON 协议，`/data` 是来宾私有持久目录。容器限制 768 MiB / 128 个进程，外层 VM 仍提供最终隔离。无透明网络和宿主挂载。

## 签名镜像安装与更新

发行者先确定可分发内核/rootfs 和依赖来源，提供 HTTPS 文件。签名工具使用原始 32 字节 Ed25519 私钥文件（只读，不提交到仓库）：

```bash
swift scripts/sign-workbench-image.swift \
  "$AGENTOS_IMAGE_SIGNING_KEY_FILE" 1.0.0 https://images.example.com/1.0.0/ \
  "$AGENTOS_RELEASE_KERNEL" "$AGENTOS_RELEASE_DISK" release-output/workbench.json
```

输出清单包含 base64 payload/signature。payload 记录版本、linux/arm64、kernel/disk 的 HTTPS 地址、字节数和 SHA-256；发行公钥需通过独立可信渠道配置到设置页。公钥不从下载的清单自动信任。

宿主验证清单后展示版本/发行者指纹/下载体积；用户确认后逐文件下载。HTTPS 地址固定公网 IP、不使用代理、不接受重定向，限制时间和文件长度，并在安装前后校验哈希。新基础镜像不可变存储，原子更新指针，拒绝相同/更低版本。已有工作间和后端磁盘继续使用原环境；新临时实例与新后端使用更新镜像。

目前没有配置公共发行地址或公钥。下载器、签名验证、基础镜像选择与升级保留语义均有代码；真实发行镜像供应链与下载服务验收仍待完成。
