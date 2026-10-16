import AgentOSCore
import Darwin
import Foundation
import Virtualization

@MainActor
public final class WorkbenchVM: NSObject, @MainActor VZVirtualMachineDelegate,
  @MainActor VZVirtioSocketListenerDelegate
{
  public let directory: URL
  private var machine: VZVirtualMachine?
  private var listener: VZVirtioSocketListener?
  private var activeToken: String?
  private var busy = false
  private var starting = false
  private var checkpointing = false
  private var restoredMemory = false
  private var connections: [UUID: VZVirtioSocketConnection] = [:]
  private var console: Pipe?
  public var onHostRequest: ((String, Value) async throws -> Value)?
  public init(directory: URL) {
    self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
  }
  public var running: Bool { machine?.state == .running }
  public func install(kernel: URL, image: URL) throws {
    guard machine == nil, !checkpointing else {
      throw HostError("conflict", "Stop the workbench before changing its image")
    }
    let fm = FileManager.default
    guard !fm.fileExists(atPath: directory.appendingPathComponent("kernel").path),
      !fm.fileExists(atPath: directory.appendingPathComponent("disk.ext4").path)
    else { throw HostError("conflict", "Workbench already initialized") }
    let staging = directory.deletingLastPathComponent().appendingPathComponent(
      "workbench-install-" + UUID().uuidString)
    try fm.createDirectory(
      at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: staging) }
    try fm.copyItem(at: kernel, to: staging.appendingPathComponent("kernel"))
    try fm.copyItem(at: image, to: staging.appendingPathComponent("disk.ext4"))
    try fm.copyItem(at: image, to: staging.appendingPathComponent("base.ext4"))
    if fm.fileExists(atPath: directory.path) {
      guard try fm.contentsOfDirectory(atPath: directory.path).isEmpty else {
        throw HostError("conflict", "Workbench directory is not empty")
      }
      try fm.removeItem(at: directory)
    }
    try fm.moveItem(at: staging, to: directory)
  }
  public func ephemeral() throws -> WorkbenchVM {
    let location = directory.deletingLastPathComponent().appendingPathComponent(
      "ephemeral-" + UUID().uuidString)
    let vm = WorkbenchVM(directory: location)
    do {
      let artifacts = try baseArtifacts()
      try vm.install(
        kernel: artifacts.kernel,
        image: artifacts.image)
      return vm
    } catch {
      try? FileManager.default.removeItem(at: location)
      throw error
    }
  }
  public func discard() async throws {
    try await stop()
    try FileManager.default.removeItem(at: directory)
  }
  public func suspend() async throws {
    // Restored processes may include services unknown to the new host process.
    guard !busy, !starting, !checkpointing, !restoredMemory, let machine,
      machine.state == .running
    else { return }
    try await machine.pause()
  }
  public func start() async throws {
    guard !checkpointing else { throw HostError("conflict", "Workbench checkpoint is in progress") }
    try await boot()
  }
  private func boot() async throws {
    if running { return }
    if let machine, machine.state == .paused {
      try await machine.resume()
      return
    }
    guard !busy else { throw HostError("conflict", "Workbench is busy") }
    guard !starting else { throw HostError("conflict", "Workbench is starting") }
    starting = true
    defer { starting = false }
    let vm = try prepareMachine()
    do {
      try await vm.start()
      let deadline = Date().addingTimeInterval(30)
      while Date() < deadline {
        do {
          let status = try await rpc("ping", args: [:])
          if status["ready"] == true { return }
        } catch {}
        try await Task.sleep(for: .milliseconds(200))
      }
      throw HostError("timeout", "Workbench did not become ready")
    } catch {
      try? await stopMachine()
      throw error
    }
  }
  private func prepareMachine() throws -> VZVirtualMachine {
    let fm = FileManager.default
    let kernel = directory.appendingPathComponent("kernel")
    let disk = directory.appendingPathComponent("disk.ext4")
    guard fm.fileExists(atPath: kernel.path), fm.fileExists(atPath: disk.path) else {
      throw HostError("unavailable", "工作间镜像尚未安装，请在设置中选择经过验证的内核和磁盘镜像")
    }
    let configuration = VZVirtualMachineConfiguration()
    let boot = VZLinuxBootLoader(kernelURL: kernel)
    boot.commandLine =
      "console=hvc0 root=/dev/vda rootfstype=ext4 rw init=/init quiet loglevel=3 panic=0"
    configuration.bootLoader = boot
    configuration.cpuCount = 2
    configuration.memorySize = 1024 * 1024 * 1024
    configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    configuration.storageDevices = [
      VZVirtioBlockDeviceConfiguration(
        attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false))
    ]
    configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    configuration.networkDevices = []
    // No directory shares: host files can only be copied by an explicitly authorized host operation.
    configuration.directorySharingDevices = []
    let platform = VZGenericPlatformConfiguration()
    let identifierFile = directory.appendingPathComponent("machine.id")
    if let data = try? Data(contentsOf: identifierFile),
      let id = VZGenericMachineIdentifier(dataRepresentation: data)
    {
      platform.machineIdentifier = id
    } else {
      platform.machineIdentifier = VZGenericMachineIdentifier()
      try platform.machineIdentifier.dataRepresentation.write(to: identifierFile)
    }
    configuration.platform = platform
    let pipe = Pipe()
    console = pipe
    let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
    serial.attachment = VZFileHandleSerialPortAttachment(
      fileHandleForReading: nil, fileHandleForWriting: pipe.fileHandleForWriting)
    configuration.serialPorts = [serial]
    pipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
    try configuration.validate()
    try configuration.validateSaveRestoreSupport()
    let vm = VZVirtualMachine(configuration: configuration)
    machine = vm
    restoredMemory = false
    vm.delegate = self
    let listener = VZVirtioSocketListener()
    listener.delegate = self
    self.listener = listener
    (vm.socketDevices.first as! VZVirtioSocketDevice).setSocketListener(listener, forPort: 5202)
    return vm
  }
  public func stop() async throws {
    guard !checkpointing else { throw HostError("conflict", "Workbench checkpoint is in progress") }
    try await stopMachine()
  }
  private func stopMachine() async throws {
    activeToken = nil
    if let machine, machine.state != .stopped { try await machine.stop() }
    machine = nil
    restoredMemory = false
    listener = nil
    console?.fileHandleForReading.readabilityHandler = nil
    console = nil
    for connection in connections.values { connection.close() }
    connections.removeAll()
  }
  public func execute(_ method: String, args: Value) async throws -> Value {
    try await start()
    guard !busy else { throw HostError("conflict", "Workbench commands are serialized") }
    busy = true
    activeToken = UUID().uuidString
    defer {
      busy = false
      activeToken = nil
    }
    return try await rpc(method, args: args, token: activeToken)
  }
  private func rpc(_ method: String, args: Value, token: String? = nil) async throws -> Value {
    guard let socket = machine?.socketDevices.first as? VZVirtioSocketDevice else {
      throw HostError("unavailable", "Workbench is not running")
    }
    let connection = try await socket.connect(toPort: 5201)
    defer { connection.close() }
    let request: Value = [
      "method": .string(method), "args": args, "token": token.map(Value.string) ?? "",
    ]
    let fd = connection.fileDescriptor
    let data = try request.encoded() + Data([10])
    let response = try await Task.detached { try Self.exchange(fd: fd, data: data) }.value
    if let error = response["error"] {
      throw HostError(
        error["code"]?.string ?? "vm_error", error["message"]?.string ?? "Guest request failed")
    }
    return response["result"] ?? .null
  }
  nonisolated static func exchange(fd: Int32, data: Data) throws -> Value {
    var timeout = timeval(tv_sec: 150, tv_usec: 0)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    try data.withUnsafeBytes { buffer in
      var sent = 0
      while sent < buffer.count {
        let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
        guard n > 0 else { throw HostError("vm_error", "Guest connection closed") }
        sent += n
      }
    }
    return try receive(fd: fd)
  }
  nonisolated static func receive(fd: Int32) throws -> Value {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while !data.contains(10) {
      let n = Darwin.read(fd, &buffer, buffer.count)
      guard n > 0, data.count + n <= 8_000_000 else {
        throw HostError("vm_error", "Guest response exceeded limit or timed out")
      }
      data.append(contentsOf: buffer.prefix(n))
    }
    return try Value.parse(String(decoding: data.prefix(while: { $0 != 10 }), as: UTF8.self))
  }
  public func listener(
    _ listener: VZVirtioSocketListener,
    shouldAcceptNewConnection connection: VZVirtioSocketConnection,
    from socketDevice: VZVirtioSocketDevice
  ) -> Bool {
    guard activeToken != nil, connections.count < 8 else { return false }
    let id = UUID()
    connections[id] = connection
    let fd = connection.fileDescriptor
    Task { [weak self] in
      guard let self else { return }
      defer {
        self.connections[id]?.close()
        self.connections[id] = nil
      }
      var timeout = timeval(tv_sec: 10, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      let response: Value
      do {
        let request = try await Task.detached { try Self.receive(fd: fd) }.value
        guard let token = self.activeToken, !token.isEmpty, request["token"]?.string == token,
          let callback = self.onHostRequest
        else { throw HostError("denied", "Expired VM authorization") }
        response = [
          "result": try await callback(request.requiredString("method"), request["args"] ?? [:])
        ]
      } catch {
        response = [
          "error": [
            "code": .string((error as? HostError)?.code ?? "vm_error"),
            "message": .string(error.localizedDescription),
          ]
        ]
      }
      if let data = try? response.encoded() + Data([10]) {
        try? await Task.detached {
          var timeout = timeval(tv_sec: 10, tv_usec: 0)
          var one: Int32 = 1
          setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
          setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
          try data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
              let count = Darwin.write(
                fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
              guard count > 0 else { throw HostError("vm_error", "VM client disconnected") }
              sent += count
            }
          }
        }.value
      }
    }
    return true
  }
  public func stats() -> Value {
    [
      "installed": .bool(
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("disk.ext4").path)),
      "running": .bool(running), "busy": .bool(busy), "memoryMiB": 1024, "cpuCount": 2,
      "checkpointing": .bool(checkpointing), "restoredMemory": .bool(restoredMemory),
      "networkInterfaces": 0, "hostDirectoryShares": 0,
    ]
  }
  public func snapshot(_ name: String) async throws -> Value {
    guard running, !busy, !starting, !checkpointing, let machine, UUID(uuidString: name) != nil
    else {
      throw HostError("conflict", "Use a UUID snapshot name while workbench is idle")
    }
    let folder = directory.appendingPathComponent("snapshots/" + name)
    guard !FileManager.default.fileExists(atPath: folder.path) else {
      throw HostError("conflict", "Snapshot already exists")
    }
    checkpointing = true
    defer { checkpointing = false }
    let staging = folder.deletingLastPathComponent().appendingPathComponent(".pending-" + name)
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: staging) }
    do {
      let sync = try await rpc("exec", args: ["cmd": "sync"])
      guard sync["exitCode"] == 0 else { throw HostError("vm_error", "Guest disk sync failed") }
      try await machine.pause()
      try await machine.saveMachineStateTo(url: staging.appendingPathComponent("state"))
      try FileManager.default.copyItem(
        at: directory.appendingPathComponent("disk.ext4"),
        to: staging.appendingPathComponent("disk.ext4"))
      try await machine.resume()
      try FileManager.default.moveItem(at: staging, to: folder)
      return ["id": .string(name)]
    } catch {
      if machine.state == .paused { try? await machine.resume() }
      throw error
    }
  }
  public func restore(_ name: String, cold: Bool = false) async throws {
    guard !busy, !starting, !checkpointing, UUID(uuidString: name) != nil else {
      throw HostError("conflict", "Workbench is busy or snapshot ID is invalid")
    }
    let folder = directory.appendingPathComponent("snapshots/" + name)
    let fm = FileManager.default
    guard fm.fileExists(atPath: folder.appendingPathComponent("state").path),
      fm.fileExists(atPath: folder.appendingPathComponent("disk.ext4").path)
    else {
      throw HostError("not_found", "Snapshot is missing")
    }
    checkpointing = true
    defer { checkpointing = false }
    let disk = directory.appendingPathComponent("disk.ext4")
    let backup = directory.appendingPathComponent("before-restore-" + UUID().uuidString + ".ext4")
    let stagedDisk = directory.appendingPathComponent("restore-" + UUID().uuidString + ".ext4")
    defer { try? fm.removeItem(at: stagedDisk) }
    // Copy the checkpoint before stopping or moving the current disk.
    try fm.copyItem(at: folder.appendingPathComponent("disk.ext4"), to: stagedDisk)
    // A failed restore must preserve acknowledged writes, including Linux's dirty page cache.
    let wasPaused = machine?.state == .paused
    if wasPaused { try await machine!.resume() }
    if running {
      do {
        let sync = try await rpc("exec", args: ["cmd": "sync"])
        guard sync["exitCode"] == 0 else { throw HostError("vm_error", "Guest disk sync failed") }
      } catch {
        if wasPaused { try? await machine?.pause() }
        throw error
      }
    }
    try await stopMachine()
    try fm.moveItem(at: disk, to: backup)
    do {
      try fm.moveItem(at: stagedDisk, to: disk)
      if cold {
        try await boot()
      } else {
        _ = try prepareMachine()
        try await machine!.restoreMachineStateFrom(url: folder.appendingPathComponent("state"))
        try await machine!.resume()
        restoredMemory = true
      }
    } catch {
      let original = error as NSError
      do {
        try await stopMachine()
        if fm.fileExists(atPath: disk.path) { try fm.removeItem(at: disk) }
        try fm.moveItem(at: backup, to: disk)
      } catch {
        throw HostError(
          "vm_restore_rollback_failed", "恢复失败，原磁盘保留在备份文件中；请停止操作并检查工作间目录。",
          details: ["backup": .string(backup.lastPathComponent), "diskRestored": false])
      }
      throw HostError(
        "vm_restore_failed",
        "工作间恢复失败，原磁盘已保留，VM 已停止。请在创建快照的 Mac 和用户下解锁后重试；若仍失败，请检查系统版本、配置及 Virtualization 日志。冷磁盘恢复需显式选择。",
        details: [
          "domain": .string(original.domain), "code": .number(Double(original.code)),
          "reason": .string(original.localizedDescription), "diskRestored": true,
        ])
    }
    try? fm.removeItem(at: backup)
  }
  public func guestDidStop(_ virtualMachine: VZVirtualMachine) { activeToken = nil }
  public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
    activeToken = nil
  }
}
